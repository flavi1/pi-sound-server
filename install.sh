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
APT=(apt-get -o DPkg::Lock::Timeout=900 -y)
# apt_run ARGS… : apt-get qui patiente si apt est déjà occupé (mises à jour
# automatiques, autre installation). DPkg::Lock::Timeout ne couvre que le verrou
# de dpkg, pas ceux du cache et des listes : on réessaie tant qu'un autre apt tourne.
apt_busy() { pgrep -x 'apt-get|apt|dpkg|unattended-upgr' >/dev/null || pgrep -f 'apt.systemd.daily' >/dev/null; }
apt_run() {
    local i
    for i in $(seq 1 120); do
        while apt_busy; do
            [[ $i -eq 1 ]] && echo "   apt est occupé (mises à jour automatiques ?) : attente…"
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
[[ -f "$CONF" ]] || install -m 644 "$HERE/audio-hub.conf" "$CONF"
install -m 755 "$F/bin/audio-hub" /usr/local/bin/audio-hub
AUSER="$(ini global user)"; AUSER="${AUSER:-hifi}"
HP="$(ini mopidy http.port)"; HP="${HP:-6680}"
MP="$(ini mopidy mpd.port)";  MP="${MP:-6600}"
IRIS="$(ini mopidy iris)"

# --- Paquets ------------------------------------------------------------------
log "Paquets PipeWire / Mopidy"
apt_run update
apt_run install pipewire pipewire-bin wireplumber pipewire-alsa dbus-user-session \
    alsa-utils python3 python3-evdev \
    gstreamer1.0-pipewire gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly gstreamer1.0-libav \
    mopidy
for p in mopidy-local mopidy-mpd; do
    apt_run install "$p" || warn "paquet $p indisponible dans les dépôts (voir README : installation pip)"
done

# --- Utilisateur audio dédié -----------------------------------------------------
log "Utilisateur « $AUSER »"
if ! id -u "$AUSER" >/dev/null 2>&1; then
    useradd --create-home --shell /usr/sbin/nologin --comment "pi-sound-server" "$AUSER"
fi
for g in audio input pipewire video; do
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

if [[ "${IRIS,,}" =~ ^(yes|true|1|on|oui)$ ]]; then
    log "Interface web Iris (pip)"
    apt_run install python3-pip python3-setuptools python3-pykka
    # --no-deps : pip ne doit JAMAIS remplacer le Mopidy de Debian par celui de PyPI
    # (Iris demande seulement Mopidy >= 3.0, déjà fourni par apt).
    pip3 install --break-system-packages --root-user-action=ignore --no-deps --upgrade "Mopidy-Iris>=3.69,<4" \
        || warn "Iris non installé (Mopidy reste pilotable en MPD : port $MP)"
fi

# --- Unités utilisateur ----------------------------------------------------------
log "Services utilisateur"
UHOME="$(getent passwd "$AUSER" | cut -d: -f6)"
install -d -o "$AUSER" -g "$AUSER" "$UHOME/.config" "$UHOME/.config/systemd" "$UHOME/.config/systemd/user"
for u in "$F"/user-units/*; do
    install -m 644 -o "$AUSER" -g "$AUSER" "$u" "$UHOME/.config/systemd/user/"
done

# --- Pare-feu (seulement si un pare-feu pi-server est en place) ----------------------
if [[ -f /etc/nftables.d/00-lan.nft ]] && grep -q 'nftables.d/\[1-9\]' /etc/nftables.conf 2>/dev/null; then
    log "Pare-feu : Mopidy (HTTP $HP + MPD $MP) limité au réseau local"
    cat > /etc/nftables.d/20-pi-sound-server.nft <<EOF
# pi-sound-server — réseau local uniquement
add rule inet filter input ip  saddr \$LAN4 tcp dport { $HP, $MP } accept
add rule inet filter input ip6 saddr \$LAN6 tcp dport { $HP, $MP } accept
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

IP="$(hostname -I | awk '{print $1}')"
log "Serveur de son prêt"
cat <<EOF
  Configuration unique : $CONF   puis  sudo audio-hub apply
  Appareils détectés   : sudo audio-hub list
  État du routage      : sudo audio-hub status
  Mopidy               : http://$IP:$HP/  (MPD : port $MP)
EOF
