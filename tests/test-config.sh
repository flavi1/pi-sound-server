#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Tests hors matériel : validation du fichier de config, génération des fichiers
# PipeWire / WirePlumber / Mopidy / systemd, transformation de config.txt.
# Usage : bash tests/test-config.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HUB=(python3 "$HERE/files/bin/audio-hub")
export AUDIO_HUB_CONF="$HERE/audio-hub.conf"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
FAILS=0
ok()   { echo "  ok   : $*"; }
fail() { echo "  FAIL : $*"; FAILS=$((FAILS+1)); }

echo "== check / generate"
"${HUB[@]}" check >/dev/null && ok "audio-hub check" || fail "audio-hub check"
"${HUB[@]}" generate "$W/gen" >/dev/null && ok "audio-hub generate" || fail "generate"
for f in .config/pipewire/pipewire.conf.d/50-audio-hub.conf \
         .config/pipewire/client.conf.d/50-audio-hub.conf \
         .config/wireplumber/wireplumber.conf.d/50-audio-hub.conf \
         .config/mopidy/mopidy.conf \
         .config/systemd/user/mopidy-scan.timer .config/systemd/user/mopidy-scan.path; do
    [[ -s "$W/gen/$f" ]] && ok "$f" || fail "$f manquant"
done
grep -q 'name = "libpipewire-module-combine-stream"' "$W/gen/.config/pipewire/pipewire.conf.d/50-audio-hub.conf" \
    && ok "MASTER (combine-stream) présent" || fail "combine-stream absent"
n_in="$(grep -c 'libpipewire-module-loopback' "$W/gen/.config/pipewire/pipewire.conf.d/50-audio-hub.conf")"
[[ "$n_in" -ge 1 ]] && ok "$n_in boucle(s) d'entrée" || fail "aucune boucle d'entrée"

# Syntaxe SPA-JSON, si l'outil de PipeWire est disponible
if command -v spa-json-dump >/dev/null; then
    for f in "$W"/gen/.config/pipewire/*/50-audio-hub.conf "$W"/gen/.config/wireplumber/*/50-audio-hub.conf; do
        spa-json-dump "$f" >/dev/null && ok "SPA-JSON valide : ${f#"$W"/gen/}" || fail "SPA-JSON invalide : $f"
    done
else
    echo "  (spa-json-dump absent : validation SPA-JSON ignorée)"
fi

# Mopidy : configuration INI lisible
python3 - "$W/gen/.config/mopidy/mopidy.conf" <<'PY' && ok "mopidy.conf lisible" || fail "mopidy.conf"
import configparser, sys
c = configparser.ConfigParser(interpolation=None); c.read(sys.argv[1])
assert c["audio"]["output"].startswith("pipewiresink"), "sortie Mopidy"
PY

echo "== erreurs de configuration détectées"
printf '[global]\nfoo = 1\n' > "$W/bad1.conf"
printf '[output.x]\ndescription = sans match\n' > "$W/bad2.conf"
printf '[output.x]\nmatch.node.name = a\nrate = abc\n' > "$W/bad3.conf"
for b in bad1 bad2 bad3; do
    if AUDIO_HUB_CONF="$W/$b.conf" "${HUB[@]}" check >/dev/null 2>&1; then fail "$b accepté"; else ok "$b refusé"; fi
done

echo "== config.txt"
cat > "$W/config.txt" <<'EOF'
# For more options and information see
# http://rptl.io/configtxt
dtparam=audio=on
camera_auto_detect=1
display_auto_detect=1
auto_initramfs=1
dtoverlay=vc4-kms-v3d
max_framebuffers=2
disable_fw_kms_setup=1
arm_64bit=1
disable_overscan=1
arm_boost=1

[cm4]
otg_mode=1

[cm5]
dtoverlay=dwc2,dr_mode=host

[all]
# >>> pi-server
[all]
dtoverlay=disable-wifi
dtoverlay=disable-bt
# <<< pi-server
EOF
"${HUB[@]}" boot-config "$W/config.txt" > "$W/c1"
grep -q '^#pi-sound-server# dtparam=audio=on$' "$W/c1" && ok "audio intégré commenté" || fail "dtparam=audio=on"
grep -q '^dtoverlay=vc4-kms-v3d,noaudio$' "$W/c1" && ok "HDMI : noaudio" || fail "noaudio"
grep -q '^dtoverlay=iqaudio-dacplus,unmute_amp$' "$W/c1" && ok "overlay du HAT" || fail "overlay HAT"
grep -q '^dtoverlay=disable-wifi$' "$W/c1" && ok "bloc pi-server conservé" || fail "bloc pi-server"
"${HUB[@]}" boot-config "$W/c1" > "$W/c2"
cmp -s "$W/c1" "$W/c2" && ok "idempotent" || fail "non idempotent"
sed 's/^manage = yes/manage = no/' "$AUDIO_HUB_CONF" > "$W/off.conf"
AUDIO_HUB_CONF="$W/off.conf" "${HUB[@]}" boot-config "$W/c1" > "$W/c3"
cmp -s "$W/config.txt" "$W/c3" && ok "réversible (manage = no restaure l'original)" || { fail "non réversible"; diff "$W/config.txt" "$W/c3" || true; }

echo
echo "$FAILS échec(s)"
[[ $FAILS -eq 0 ]]
