# shellcheck shell=sh
# pi-sound-server : état du serveur son à chaque connexion (SSH, console)
if [ -r /run/pi-sound-server/ready ]; then
    cat /run/pi-sound-server/ready
elif systemctl is-active --quiet audio-hub-ready.service 2>/dev/null; then
    echo "*** pi-sound-server : démarrage en cours (message quand tout sera prêt) ***"
fi
