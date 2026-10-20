#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
#  pi-sound-server — serveur de son (réseau local uniquement)
#   - PipeWire + WirePlumber sous un utilisateur dédié (sans bureau graphique)
#   - MASTER virtuel : toutes les entrées -> MASTER -> toutes les sorties
#   - knob USB -> volume de MASTER
#   - Mopidy (+ Iris) qui lit /media (peu importe ce qui le remplit)
#   - /boot/firmware/config.txt : HAT, audio intégré et HDMI coupés
#
#  Autonome : fonctionne seul sur Raspberry Pi OS (Debian). Si pi-server est
#  présent, ses règles de pare-feu sont simplement complétées.
#
#     sudo bash install.sh [--non-interactive]
#
#  Configuration unique : /etc/pi-sound-server/audio-hub.conf
#                         puis  sudo audio-hub apply
#  Idempotent : peut être relancé.
# =============================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "À lancer avec sudo."; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F="$HERE/files"
CONF_DIR=/etc/pi-sound-server
CONF="$CONF_DIR/audio-hub.conf"
export DEBIAN_FRONTEND=noninteractive
# --no-install-recommends : seulement les dépendances strictes (carte SD de petite
# taille ; les « recommandés » tirent des centaines de Mo inutiles ici).
APT=(apt-get -o DPkg::Lock::Timeout=900 -o APT::Install-Recommends=false -y)
# apt_run ARGS… : apt-get qui patiente si apt est déjà occupé (mises à jour
# automatiques, autre installation). DPkg::Lock::Timeout ne couvre que le verrou
# de dpkg, pas ceux du cache et des listes : on réessaie tant qu'un autre apt tourne.
# apt_busy : vrai si un autre programme tient un verrou d'apt/dpkg. On teste les
# verrous eux-mêmes (fcntl, comme apt), pas les noms de processus : le démon de
# veille d'unattended-upgrades tourne en permanence et ne doit pas compter.
apt_busy() {
    python3 - <<'PY'
import fcntl, os, sys
for f in ("/var/lib/dpkg/lock-frontend", "/var/lib/dpkg/lock",
          "/var/cache/apt/archives/lock", "/var/lib/apt/lists/lock"):
    try:
        fd = os.open(f, os.O_RDWR)
    except OSError:
        continue
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.lockf(fd, fcntl.LOCK_UN)
    except OSError:
        sys.exit(0)          # verrou tenu par un autre programme
    finally:
        os.close(fd)
sys.exit(1)
PY
}
apt_run() {
    local _ waited=0
    for _ in $(seq 1 120); do
        while apt_busy; do
            if [[ $waited -eq 0 ]]; then
                echo "   apt est occupé par un autre programme : attente (voir : sudo journalctl -fu apt-daily -u apt-daily-upgrade)"
                waited=1
            fi
            sleep 5
        done
        "${APT[@]}" "$@" && return 0
        apt_busy || return 1      # échec réel (paquet introuvable…) : on s'arrête
        sleep 5
    done
    return 1
}
log()  { printf '\n\033[1;35m[pi-sound-server]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
# lecture simple d'une clé dans une section INI : ini SECTION CLÉ
ini() {
    awk -F= -v s="[$1]" -v k="$2" '
        /^[[:space:]]*\[/ { cur=$0; gsub(/[[:space:]]/,"",cur); next }
        cur==s { key=$1; gsub(/[[:space:]]/,"",key); if (key==k) { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); sub(/[[:space:]]+$/,"",v); print v; exit } }
    ' "$CONF"
}

# --- Configuration ------------------------------------------------------------
mkdir -p "$CONF_DIR"
# La configuration du dépôt est déployée à chaque installation / mise à jour.
# L'ancienne est sauvegardée ; un code PIN Bluetooth personnalisé qui n'est pas
# dans le dépôt (public) est déplacé dans local.conf, jamais écrasé.
LOCAL="$CONF_DIR/local.conf"
if [[ -f "$CONF" ]] && ! cmp -s "$HERE/audio-hub.conf" "$CONF"; then
    OLDPIN="$(ini bluetooth pin)"
    NEWPIN="$(CONF="$HERE/audio-hub.conf" ini bluetooth pin)"
    if [[ -n "$OLDPIN" && "$OLDPIN" != "$NEWPIN" && ! -f "$LOCAL" ]]; then
        install -m 600 /dev/null "$LOCAL"
        printf '# Réglages propres à cette Pi (lus après audio-hub.conf, jamais écrasés)\n[bluetooth]\npin = %s\n' "$OLDPIN" > "$LOCAL"
        log "Code PIN Bluetooth personnalisé conservé dans $LOCAL"
    fi
    cp -a "$CONF" "$CONF.avant-maj"
    log "Configuration du dépôt déployée (ancienne : $CONF.avant-maj)"
fi
install -m 644 "$HERE/audio-hub.conf" "$CONF"
install -m 755 "$F/bin/audio-hub" /usr/local/bin/audio-hub
install -m 755 "$F/bin/audio-hub-diag" /usr/local/bin/audio-hub-diag
install -m 755 "$F/bin/audio-hub-fix-mopidy" /usr/local/bin/audio-hub-fix-mopidy
AUSER="$(ini global user)"; AUSER="${AUSER:-hifi}"
HP="$(ini mopidy http.port)"; HP="${HP:-6680}"
MP="$(ini mopidy mpd.port)";  MP="${MP:-6600}"
WEB="$(ini mopidy web)"; WEB="${WEB:-rompr}"
WEBPORT="$(ini mopidy web.port)"; WEBPORT="${WEBPORT:-80}"
CODECS="$(ini mopidy extra-codecs)"; CODECS="${CODECS:-no}"
BT="$(ini bluetooth enabled)"; BT="${BT:-no}"

# --- Paquets ------------------------------------------------------------------
log "Paquets PipeWire / Mopidy"
# Espace libre : PipeWire + Mopidy ≈ 250 Mo, + ≈ 300 Mo si codecs supplémentaires
NEED_MB=400
[[ "${CODECS,,}" =~ ^(yes|true|1|on|oui)$ ]] && NEED_MB=750
NEED_MB=$((NEED_MB + 60))   # nginx + PHP (+ RompR)
FREE_MB="$(df -Pm / | awk 'NR==2 {print $4}')"
if (( FREE_MB < NEED_MB )); then
    warn "Espace libre insuffisant sur / : ${FREE_MB} Mo, il en faut environ ${NEED_MB}."
    warn "Libérez de la place (sudo apt-get clean) ou utilisez une carte plus grande."
    exit 1
fi

apt_run update
# Audio uniquement : FLAC, MP3, OGG/Vorbis, Opus, WAV, AIFF (plugins base + good).
# Pas de plugins « bad » / « ugly » : codecs vidéo, rendu graphique, X11…
apt_run install pipewire pipewire-bin wireplumber pipewire-alsa dbus-user-session \
    alsa-utils python3 python3-evdev \
    gstreamer1.0-pipewire gstreamer1.0-alsa gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    mopidy
if [[ "${CODECS,,}" =~ ^(yes|true|1|on|oui)$ ]]; then
    log "Codecs supplémentaires (AAC, M4A, ALAC, WMA… via ffmpeg) : ≈ 300 Mo"
    apt_run install gstreamer1.0-libav
fi
if [[ "${BT,,}" =~ ^(yes|true|1|on|oui)$ ]]; then
    log "Bluetooth (BlueZ, codecs Bluetooth de PipeWire, agent de jumelage)"
    apt_run install bluez libspa-0.2-bluetooth python3-dbus python3-gi
fi
for p in mopidy-local mopidy-mpd; do
    apt_run install "$p" || warn "paquet $p indisponible dans les dépôts (voir README : installation pip)"
done

# --- Utilisateur audio dédié -----------------------------------------------------
log "Utilisateur « $AUSER »"
if ! id -u "$AUSER" >/dev/null 2>&1; then
    useradd --create-home --shell /usr/sbin/nologin --comment "pi-sound-server" "$AUSER"
fi
for g in audio input pipewire video bluetooth; do
    getent group "$g" >/dev/null && usermod -aG "$g" "$AUSER"
done
# Le gestionnaire systemd de l'utilisateur démarre au boot, sans connexion
loginctl enable-linger "$AUSER"
AUID="$(id -u "$AUSER")"
for _ in $(seq 1 30); do [[ -S "/run/user/$AUID/bus" ]] && break; sleep 1; done

# --- Mopidy : pas de service système, il tourne dans la session de $AUSER -------
systemctl disable --now mopidy.service 2>/dev/null || true
systemctl mask mopidy.service 2>/dev/null || true
mkdir -p /media

if [[ "$WEB" == iris ]]; then
    log "Interface web Iris (pip)"
    apt_run install python3-pip python3-setuptools python3-pykka
    # --no-deps : pip ne doit JAMAIS remplacer le Mopidy de Debian par celui de PyPI
    # (Iris demande seulement Mopidy >= 3.0, déjà fourni par apt).
    pip3 install --break-system-packages --root-user-action=ignore --no-deps --upgrade "Mopidy-Iris>=3.69,<4" \
        || warn "Iris non installé (Mopidy reste pilotable en MPD : port $MP)"
elif pip3 show Mopidy-Iris >/dev/null 2>&1; then
    log "Retrait d'Iris (interface web : $WEB)"
    pip3 uninstall -y --break-system-packages --root-user-action=ignore Mopidy-Iris || true
fi

# --- Site web de la Pi (nginx + PHP-FPM) : dossier www/ du dépôt sur http://<pi>/ ----
#     et RompR sur http://<pi>/rompr/ si [mopidy] web = rompr
SITE=/var/www/hifi
PRIVATE=/var/lib/pi-sound-server/private
ROMPR_WEB=/var/www/rompr-web
log "Site web de la Pi (nginx + PHP) : port $WEBPORT"
apt_run install nginx php-fpm php-curl php-xml php-mbstring php-sqlite3 php-gd php-intl curl
# www/ du dépôt -> $SITE (copie fidèle : ce qui a disparu du dépôt disparaît aussi)
rm -rf "$SITE.new"
cp -r "$HERE/www" "$SITE.new"
chown -R root:root "$SITE.new"; chmod -R u=rwX,go=rX "$SITE.new"
rm -rf "$SITE.old"; [[ -d "$SITE" ]] && mv "$SITE" "$SITE.old"
mv "$SITE.new" "$SITE"; rm -rf "$SITE.old"
# Dossier privé du site (SQLite…) : hors du web, écrit par PHP (www-data), jamais
# écrasé. Les fichiers de private/ du dépôt n'y sont copiés que s'ils manquent.
install -d -m 750 -o www-data -g www-data "$PRIVATE"
if [[ -d "$HERE/private" ]]; then
    cp -rn "$HERE/private/." "$PRIVATE/"
    rm -f "$PRIVATE/.gitkeep"
    chown -R www-data:www-data "$PRIVATE"
fi
ROMPR_LOC=""
if [[ "$WEB" == rompr ]]; then
    log "Interface web RompR"
    REL="$(curl -fsSL --max-time 30 https://api.github.com/repos/fatg3erman/RompR/releases/latest || true)"
    TAG="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' <<<"$REL" 2>/dev/null || true)"
    URL="$(python3 -c 'import json,sys
d = json.load(sys.stdin)
z = [a["browser_download_url"] for a in d.get("assets", []) if a["name"].endswith(".zip")]
print(z[0] if z else d["zipball_url"])' <<<"$REL" 2>/dev/null || true)"
    mkdir -p "$ROMPR_WEB"
    if [[ -z "$TAG" || -z "$URL" ]]; then
        warn "Dernière version de RompR introuvable (GitHub injoignable ?) : version installée conservée"
    elif [[ "$(cat "$ROMPR_WEB/.rompr-version" 2>/dev/null)" != "$TAG" ]]; then
        TMPR="$(mktemp -d)"
        if curl -fsSL --max-time 300 -o "$TMPR/rompr.zip" "$URL" && python3 -m zipfile -e "$TMPR/rompr.zip" "$TMPR/x"; then
            # le index.php le moins profond = racine de RompR (« rompr/ » ou dossier du dépôt)
            SRC="$(dirname "$(find "$TMPR/x" -maxdepth 3 -name index.php | awk -F/ '{print NF" "$0}' | sort -n | head -1 | cut -d' ' -f2-)")"
            if [[ -f "$SRC/index.php" ]]; then
                mkdir -p "$ROMPR_WEB/rompr"
                # préférences et pochettes conservées d'une version à l'autre
                tar -C "$SRC" --exclude=./prefs --exclude=./albumart -cf - . | tar -C "$ROMPR_WEB/rompr" -xf -
                echo "$TAG" > "$ROMPR_WEB/.rompr-version"
                log "RompR $TAG installé"
            else
                warn "Archive RompR inattendue : version installée conservée"
            fi
        else
            warn "Téléchargement de RompR impossible : version installée conservée"
        fi
        rm -rf "$TMPR"
    fi
    mkdir -p "$ROMPR_WEB/rompr/prefs" "$ROMPR_WEB/rompr/albumart"
    chown -R www-data:www-data "$ROMPR_WEB/rompr/prefs" "$ROMPR_WEB/rompr/albumart"
    ROMPR_LOC="$(sed "s#@ROMPR_ROOT@#$ROMPR_WEB#g" "$F/rompr-location.conf.in")"
fi
for d in /etc/php/*/fpm/conf.d; do
    [[ -d "$d" ]] && install -m 644 "$F/rompr-php.ini" "$d/99-rompr.ini"
done
python3 - "$F/www-nginx.conf.in" "$WEBPORT" "$SITE" "$ROMPR_LOC" "$PRIVATE" > /etc/nginx/sites-available/hifi <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
for k, v in (("@PORT@", sys.argv[2]), ("@SITE@", sys.argv[3]), ("@ROMPR@", sys.argv[4]),
             ("@PRIVATE@", sys.argv[5])):
    t = t.replace(k, v)
print(t, end="")
PY
ln -sf /etc/nginx/sites-available/hifi /etc/nginx/sites-enabled/hifi
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/rompr /etc/nginx/sites-available/rompr
nginx -t && systemctl enable nginx && systemctl restart nginx
for u in /lib/systemd/system/php*-fpm.service; do
    [[ -f "$u" ]] && systemctl enable "$(basename "$u")" && systemctl restart "$(basename "$u")"
done

# Python 3.13 n'a plus le module imghdr, encore utilisé par Mopidy-Local (recherche
# par artiste / album) : rétroportage officiel « standard-imghdr ».
if ! python3 -c 'import imghdr' 2>/dev/null; then
    log "Module imghdr pour Mopidy-Local (Python 3.13+)"
    apt_run install python3-pip
    pip3 install --break-system-packages --root-user-action=ignore standard-imghdr \
        || warn "standard-imghdr non installé : Mopidy-Local (recherche) désactivé"
fi

# Mopidy + GStreamer 1.26.2 : analyseur cassé (radios refusées, indexation en échec).
# Corrigé maintenant, puis après chaque opération dpkg (mise à jour du paquet mopidy).
/usr/local/bin/audio-hub-fix-mopidy || warn "correctif de l'analyseur de Mopidy non appliqué"
install -m 644 "$F/80pi-sound-server-mopidy" /etc/apt/apt.conf.d/80pi-sound-server-mopidy

# --- Unités utilisateur ----------------------------------------------------------
log "Services utilisateur"
UHOME="$(getent passwd "$AUSER" | cut -d: -f6)"
install -d -o "$AUSER" -g "$AUSER" "$UHOME/.config" "$UHOME/.config/systemd" "$UHOME/.config/systemd/user"
for u in "$F"/user-units/*; do
    install -m 644 -o "$AUSER" -g "$AUSER" "$u" "$UHOME/.config/systemd/user/"
done

# --- Service système Bluetooth (activé ou non par « audio-hub apply ») -------------
install -m 644 "$F/system-units/audio-hub-bluetooth.service" /etc/systemd/system/
# Annonce « serveur son prêt » (console, sessions ouvertes, connexion SSH)
install -m 644 "$F/system-units/audio-hub-ready.service" /etc/systemd/system/
install -m 644 "$F/profile.d/pi-sound-server.sh" /etc/profile.d/pi-sound-server.sh
systemctl daemon-reload
systemctl enable audio-hub-ready.service

# --- Pare-feu (seulement si un pare-feu pi-server est en place) ----------------------
if [[ -f /etc/nftables.d/00-lan.nft ]] && grep -q 'nftables.d/\[1-9\]' /etc/nftables.conf 2>/dev/null; then
    PORTS="$HP, $MP, $WEBPORT"
    log "Pare-feu : Mopidy / interface web (ports $PORTS) limités au réseau local"
    cat > /etc/nftables.d/20-pi-sound-server.nft <<EOF
# pi-sound-server — réseau local uniquement
add rule inet filter input ip  saddr \$LAN4 tcp dport { $PORTS } accept
add rule inet filter input ip6 saddr \$LAN6 tcp dport { $PORTS } accept
EOF
    nft -c -f /etc/nftables.conf && systemctl restart nftables
    if systemctl is-active --quiet fail2ban; then systemctl restart fail2ban; fi
else
    warn "Pas de pare-feu pi-server : les ports $HP et $MP ne sont filtrés par rien."
    warn "Ne les exposez pas sur Internet (aucune redirection sur la box)."
fi

# --- Génération, config.txt et démarrage ---------------------------------------------
log "Génération de la configuration et démarrage"
/usr/local/bin/audio-hub apply

if ! aplay -l 2>/dev/null | grep -qiE 'iqaudio|digiamp'; then
    echo
    if [[ -f /var/run/reboot-required ]]; then
        warn "Le HAT apparaîtra après le redémarrage (sudo reboot)."
    else
        warn "Le HAT DigiAMP+ n'apparaît pas dans « aplay -l ». Essayez dans $CONF :"
        warn "  [boot] overlay = rpi-digiampplus,unmute_amp   puis sudo audio-hub apply && sudo reboot"
    fi
fi

apt-get clean
IP="$(hostname -I | awk '{print $1}')"
log "Serveur de son prêt"
cat <<EOF
  Configuration unique : $CONF   puis  sudo audio-hub apply
  Appareils détectés   : sudo audio-hub list
  État du routage      : sudo audio-hub status
  Mopidy               : MPD sur le port $MP, API HTTP sur le port $HP
EOF
WURL="http://$IP$( [[ "$WEBPORT" == 80 ]] || echo ":$WEBPORT")"
echo "  Site de la Pi        : $WURL/  (dossier www/ du dépôt)"
case "$WEB" in
    rompr) echo "  Interface web        : $WURL/rompr/  (RompR)" ;;
    iris)  echo "  Interface web        : http://$IP:$HP/  (Iris)" ;;
esac
