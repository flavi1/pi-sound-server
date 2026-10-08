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
         .config/wireplumber/wireplumber.conf.d/51-audio-hub-bluetooth.conf \
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
    for f in "$W"/gen/.config/pipewire/*/50-audio-hub.conf "$W"/gen/.config/wireplumber/*/5?-audio-hub*.conf; do
        spa-json-dump "$f" >/dev/null && ok "SPA-JSON valide : ${f#"$W"/gen/}" || fail "SPA-JSON invalide : $f"
    done
else
    echo "  (spa-json-dump absent : validation SPA-JSON ignorée)"
fi

# Mopidy : configuration INI lisible
python3 - "$W/gen/.config/mopidy/mopidy.conf" <<'PY' && ok "mopidy.conf lisible" || fail "mopidy.conf"
import configparser, sys
c = configparser.ConfigParser(interpolation=None); c.read(sys.argv[1])
out = c["audio"]["output"]
assert out.endswith("pipewiresink target-object=MASTER client-name=Mopidy"), "sortie Mopidy"
assert "audio/x-raw,format=F32LE,rate=192000,channels=2" in out, "format fixe Mopidy"
assert "audioresample quality=10" in out, "qualité du rééchantillonnage"
PY
sed 's/^fixed-format = yes/fixed-format = no/' "$AUDIO_HUB_CONF" > "$W/nofix.conf"
AUDIO_HUB_CONF="$W/nofix.conf" "${HUB[@]}" generate "$W/gen-nofix" >/dev/null
grep -q '^output = pipewiresink target-object=MASTER' "$W/gen-nofix/.config/mopidy/mopidy.conf" \
    && ok "fixed-format = no : sortie directe" || fail "fixed-format = no"

echo "== Bluetooth"
BTW="$W/gen/.config/wireplumber/wireplumber.conf.d/51-audio-hub-bluetooth.conf"
grep -q 'monitor.bluez.seat-monitoring = "disabled"' "$BTW" && ok "BT : sans session graphique" || fail "BT seat-monitoring"
grep -q 'bluez5.roles = \[ "a2dp_sink" \]' "$BTW" && ok "BT : enceinte A2DP uniquement" || fail "BT roles"
grep -qE 'audio.rate|bluez5.codecs' "$BTW" && fail "BT : fréquence ou codec imposé" || ok "BT : ni fréquence ni codec imposés"
sed '/^\[bluetooth\]/,/^\[/ s/^enabled = yes/enabled = no/' "$AUDIO_HUB_CONF" > "$W/nobt.conf"
AUDIO_HUB_CONF="$W/nobt.conf" "${HUB[@]}" generate "$W/gen-nobt" >/dev/null
grep -q 'monitor.bluez = "disabled"' "$W/gen-nobt/.config/wireplumber/wireplumber.conf.d/51-audio-hub-bluetooth.conf" \
    && ok "BT désactivé : moniteur bluez coupé" || fail "BT désactivé"
printf '[global]\n' > "$W/nosec.conf"
AUDIO_HUB_CONF="$W/nosec.conf" "${HUB[@]}" check | grep -q 'bluetooth    : inactif' \
    && ok "section [bluetooth] absente : Bluetooth inactif" || fail "défaut Bluetooth"
"${HUB[@]}" check | grep -q 'code PIN 1234' && ok "code PIN par défaut 1234" || fail "PIN 1234"
sed 's/^pin = 1234/pin = 98765/' "$AUDIO_HUB_CONF" > "$W/pin.conf"
AUDIO_HUB_CONF="$W/pin.conf" "${HUB[@]}" check | grep -q 'code PIN 98765' && ok "code PIN modifiable" || fail "PIN modifié"

echo "== erreurs de configuration détectées"
printf '[global]\nfoo = 1\n' > "$W/bad1.conf"
printf '[output.x]\ndescription = sans match\n' > "$W/bad2.conf"
printf '[output.x]\nmatch.node.name = a\nrate = abc\n' > "$W/bad3.conf"
printf '[input.x]\nmatch.node.name = a\ngain-db = 50\n' > "$W/bad4.conf"
printf '[input.x]\nmatch.node.name = a\ngain-db = fort\n' > "$W/bad5.conf"
printf '[input.x]\nmatch.node.name = a\ngain-db = +6\n' > "$W/good1.conf"
printf '[bluetooth]\npin = 12\n' > "$W/bad6.conf"
printf '[bluetooth]\npin = abcd\n' > "$W/bad7.conf"
printf '[bluetooth]\ncode = 1234\n' > "$W/bad8.conf"
if AUDIO_HUB_CONF="$W/good1.conf" "${HUB[@]}" check >/dev/null 2>&1; then ok "gain-db = +6 accepté"; else fail "gain-db = +6 refusé"; fi
for b in bad1 bad2 bad3 bad4 bad5 bad6 bad7 bad8; do
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
grep -q '^#pi-sound-server# dtoverlay=disable-bt$' "$W/c1" && ok "Bluetooth activé : disable-bt commenté" || fail "disable-bt"
AUDIO_HUB_CONF="$W/nobt.conf" "${HUB[@]}" boot-config "$W/c1" > "$W/c4"
grep -q '^dtoverlay=disable-bt$' "$W/c4" && ok "Bluetooth désactivé : disable-bt rétabli" || fail "disable-bt rétabli"
"${HUB[@]}" boot-config "$W/c1" > "$W/c2"
cmp -s "$W/c1" "$W/c2" && ok "idempotent" || fail "non idempotent"
sed 's/^manage = yes/manage = no/' "$AUDIO_HUB_CONF" > "$W/off.conf"
AUDIO_HUB_CONF="$W/off.conf" "${HUB[@]}" boot-config "$W/c1" > "$W/c3"
cmp -s "$W/config.txt" "$W/c3" && ok "réversible (manage = no restaure l'original)" || { fail "non réversible"; diff "$W/config.txt" "$W/c3" || true; }

echo
echo "$FAILS échec(s)"
[[ $FAILS -eq 0 ]]
