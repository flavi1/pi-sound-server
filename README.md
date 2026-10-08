# pi-sound-server

[![CI](https://github.com/flavi1/pi-sound-server/actions/workflows/ci.yml/badge.svg)](https://github.com/flavi1/pi-sound-server/actions/workflows/ci.yml)

Hub audio pour Raspberry Pi 4 / 5 sans bureau graphique : **toutes les entrées →
MASTER → toutes les sorties**, branchement / débranchement à chaud, knob USB pour le
volume global, Mopidy pour lire `/media`, enceinte Bluetooth protégée par code PIN.
Réseau local uniquement.

PipeWire + WirePlumber tournent sous un utilisateur système dédié (`hifi`).
**Une seule configuration : `/etc/pi-sound-server/audio-hub.conf`**, appliquée par
`sudo audio-hub apply`.

Module autonome : il s'installe seul sur Raspberry Pi OS Lite, ou via
[pi-server](https://github.com/flavi1/pi-server) qui ajoute le socle (mises à jour
automatiques, pare-feu, SSH) et la mise à jour par `sudo pi-server update`.

## 1. Architecture

```
  ENTRÉES (candidates)                                    SORTIES (candidates)
  ───────────────────                                     ────────────────────
  Platine Sony USB  192 kHz/24 ─► boucle ─┐          ┌──► DigiAMP+ HAT   (horloge maître)
  Adaptateur S/PDIF  96 kHz    ─► boucle ─┼─►  MASTER ┼──► Topping DX3 Pro+ USB
  Mopidy (fichiers de /media)  ───────────┘   192 kHz └──► (toute autre sortie listée)
                                              volume ◄── knob USB
```

- **MASTER** est un périphérique virtuel (module PipeWire *combine-stream*). Il reçoit
  tout et renvoie une copie vers **chaque sortie candidate présente**. Son volume est
  le volume global, piloté par le knob.
- Chaque **entrée** candidate est raccordée en permanence à MASTER par une boucle
  (*module-loopback*). Pas de micro, donc pas de larsen ; la platine et le PC peuvent
  jouer en même temps (mixage).
- Le graphe tourne **en permanence à 192 kHz**, calculs internes en virgule flottante
  32 bits. La platine est lue à sa résolution native ; le S/PDIF est ouvert à 96 kHz
  (sa fréquence réelle) puis suréchantillonné ×2 ; les fichiers Mopidy (44,1/48 kHz…)
  sont suréchantillonnés. Rééchantillonneur réglé en qualité 10 (défaut PipeWire : 4).
- Chaque appareil a son propre quartz : le **HAT, toujours présent, fournit l'horloge**
  (`driver-priority` le plus élevé), les autres s'y synchronisent par rééchantillonnage
  adaptatif. C'est ce qui permet de mélanger des appareils USB indépendants sans
  craquements ni dérive.

### Branchement / débranchement à chaud

PipeWire ne sait pas nativement « raccorder tel appareil à tel endroit dès qu'il
apparaît » ; c'est ce que fait la configuration générée :

1. Une règle **WirePlumber** reconnaît chaque appareil (lignes `match.*`) et lui donne
   un nom stable : `hub.out.amp`, `hub.out.dac`, `hub.in.turntable`, `hub.in.spdif`…
2. **Sorties** : MASTER crée une copie vers chaque nœud `hub.out.*` dès qu'il apparaît,
   et la supprime quand il disparaît.
3. **Entrées** : chaque boucle cible son `hub.in.*` avec `node.dont-fallback` +
   `node.linger` : appareil absent → la boucle attend (sans jamais se rabattre sur une
   autre entrée). Sa sortie n'est **reliée à MASTER que lorsque l'appareil fournit
   réellement du son** (service `audio-hub-links`), et déliée dès qu'il disparaît : une
   boucle dont l'appareil n'a jamais été vu depuis le démarrage peut émettre des
   valeurs invalides qui rendraient **tout MASTER muet** (défaut constaté : silence
   après chaque démarrage tant que la platine n'avait pas été allumée).
4. Les appareils ne sont jamais mis en veille (pas de « clac » sur l'ampli).

Allumer/éteindre le DAC ou la platine n'importe quand est donc sans conséquence pour le
reste. Le PC éteint derrière l'adaptateur S/PDIF (toujours branché) donne simplement
du silence.

## 2. Installation

Avec pi-server : choisir le module `sound` dans `prepare.sh`, ou plus tard
`sudo pi-server add sound`.

Seul :

```bash
sudo apt install -y git
sudo git clone https://github.com/flavi1/pi-sound-server /opt/pi-sound-server
sudo bash /opt/pi-sound-server/install.sh
sudo reboot        # nécessaire la première fois (HAT activé dans config.txt)
```

Le script installe PipeWire, WirePlumber, Mopidy (+ mopidy-local, mopidy-mpd, Iris via
pip), crée l'utilisateur `hifi` (groupes `audio`, `input`), active le *linger* (sa
session systemd démarre au boot sans connexion), installe la config par défaut puis
lance `audio-hub apply`. Sans pare-feu pi-server, il prévient que les ports Mopidy ne
sont pas filtrés.

Mise à jour manuelle : `sudo pi-server update pi-sound-server`, ou sans pi-server :
`sudo git -C /opt/pi-sound-server pull && sudo bash /opt/pi-sound-server/install.sh`.
Votre `/etc/pi-sound-server/audio-hub.conf` n'est jamais écrasé.

### Démarrage : config.txt

`audio-hub apply` gère aussi `/boot/firmware/config.txt` (section `[boot]` du fichier
de config) :

- ajoute un bloc `# >>> pi-sound-server … # <<< pi-sound-server` avec l'overlay du HAT
  (`dtoverlay=iqaudio-dacplus,unmute_amp`) et `dtparam=audio=off` ;
- commente `dtparam=audio=on` (préfixe `#pi-sound-server# `, réversible) ;
- ajoute `noaudio` à la ligne `dtoverlay=vc4-kms-v3d` (audio HDMI coupé, affichage
  conservé) ;
- si `[bluetooth] enabled = yes` : commente `dtoverlay=disable-bt` (même préfixe), y
  compris dans le bloc radio de pi-server, pour rallumer le Bluetooth.

Tout est réversible (`manage = no` puis `sudo audio-hub apply` restaure l'original),
une copie est gardée dans `config.txt.pi-sound-server.orig`. Un changement demande un redémarrage (signalé à la
connexion SSH).

## 3. Adapter la configuration à VOS appareils

Les noms exacts des appareils USB dépendent du fabricant. Après installation,
**allumez tout** (DAC, platine, PC sur l'optique) puis :

```bash
sudo audio-hub list
```

Exemple de sortie :

```
==== SORTIES (Audio/Sink) ====
  [52] node.name = hub.out.amp   (état : running)
       alsa.card_name       = IQaudIODAC
  [71] node.name = alsa_output.usb-Topping_DX3Pro_-00.analog-stereo  (état : suspended)
       alsa.card_name       = DX3Pro+
       device.vendor.id     = 0x152a
==== ENTRÉES (Audio/Source) ====
  [80] node.name = alsa_input.usb-C-Media_Electronics_Inc._USB_Audio_Device-00.iec958-stereo
```

Un appareil qui s'appelle encore `alsa_…` n'est reconnu par aucune section : copiez
une partie stable de son `node.name` (ou son `alsa.card_name`) dans
`/etc/pi-sound-server/audio-hub.conf` :

```ini
[input.spdif]
description = Entrée optique S/PDIF (son du PC)
match.node.name = ~alsa_input\.usb-C-Media_Electronics.*USB_Audio_Device.*
rate = 96000
```

puis :

```bash
sudo audio-hub apply      # régénère tout, redémarre la pile audio (~3 s de coupure)
sudo audio-hub status     # MASTER, entrées/sorties présentes, liens actifs
```

### Référence du fichier

| Section | Clé | Rôle |
|---|---|---|
| `[global]` | `user` | utilisateur qui exécute la pile audio |
| | `master.name`, `master.description` | nom du périphérique virtuel |
| | `clock.rate`, `clock.allowed-rates` | fréquence du graphe (192000 seule = fixe) |
| | `clock.quantum` (+ min/max) | taille de bloc ; augmenter si craquements |
| | `resample.quality` | 0..14 |
| | `master.initial-volume`, `master.max-volume` | volume au 1er démarrage, plafond du knob |
| | `latency-compensate` | met HAT et DAC parfaitement en phase |
| | `disable-unlisted` | désactive les appareils non listés |
| `[knob]` | `device` | `auto` ou `/dev/input/by-id/usb-…-event-…` |
| | `step`, `press`, `grab` | pas, action de l'appui (`mute`/`playpause`/`none`), capture exclusive |
| `[output.<id>]` | `match.<prop>` | critères (ET logique, `~` = expression régulière) |
| | `rate`, `format` | fréquence / format matériel imposés |
| | `driver-priority` | la plus haute présente fournit l'horloge |
| | `period-size`, `headroom` | réglages ALSA fins (USB capricieux) |
| | `enabled` | `no` pour garder la section sans l'utiliser |
| `[input.<id>]` | mêmes clés + `gain-db` | gain de l'entrée dans MASTER, en dB (-40 à +24) : équilibrer platine / PC / Mopidy |
| `[boot]` | `manage`, `file`, `overlay`, `disable-onboard-audio`, `disable-hdmi-audio` | config.txt (voir plus haut) |
| `[bluetooth]` | `enabled`, `name`, `pin`, `discoverable` | enceinte Bluetooth (voir § Bluetooth) |
| `[mopidy]` | `http.port`, `mpd.port`, `media-dirs`, `iris`, `scan-interval-minutes` | |
| | `fixed-format` | `yes` : format de sortie constant (voir § Mopidy) |
| | `extra-codecs` | `no` : FLAC, MP3, OGG, Opus, WAV, AIFF. `yes` : + AAC/M4A/ALAC/WMA (ffmpeg, ≈ 300 Mo), puis relancer `install.sh` |

Ajouter un appareil = ajouter une section `[output.xxx]` ou `[input.xxx]`.

### Le knob

```bash
sudo audio-hub knob-list
# /dev/input/event3
#     nom : USB Volume Knob
#     chemin stable : /dev/input/by-id/usb-XXXX_USB_Volume_Knob-event-if00
```

En `auto` (défaut), tous les périphériques **USB** ayant des touches de volume ou une
molette sont écoutés en même temps (les entrées HDMI-CEC de la Pi sont ignorées). Pour
en imposer un : son chemin stable dans `[knob] device = …`.

Le knob agit **uniquement sur le volume de MASTER** ; les appareils restent à volume fixe
(100 %). Pour voir le volume en direct pendant qu'on tourne le knob :

```bash
sudo audio-hub volume watch      # MASTER  31 %  [#########-----]  -30.5 dB
sudo audio-hub volume +5%        # ou -5%, 40%, mute, unmute
```

Le démon gère les touches Volume+/Volume−/Mute et les molettes (`REL_DIAL`), survit au
débranchement du knob, et mémorise le volume (restauré au redémarrage, plafonné à
`master.max-volume`). Chaque cran est aussi écrit dans son journal :
`sudo journalctl -f _SYSTEMD_USER_UNIT=audio-hub-knob.service`.

Sensibilité : `step` (0.02 par défaut) sur l'échelle de volume de PipeWire, soit
environ 1 à 2 dB par cran dans la plage d'écoute habituelle.

### Bluetooth

La Pi se présente comme une **enceinte** (nom : celui de la machine, par exemple
`hifi`). N'importe quel téléphone peut s'y connecter, mais **seulement après avoir
saisi le code PIN** de la configuration (`1234` par défaut) :

```ini
[bluetooth]
enabled = yes
name = auto          # nom affiché sur les téléphones
pin = 1234           # 4 à 16 chiffres
discoverable = yes   # no : seuls les téléphones déjà jumelés se connectent
```

puis `sudo audio-hub apply` (un redémarrage est demandé si `config.txt` contenait
`dtoverlay=disable-bt`).

Sur le téléphone : Bluetooth → rechercher → `hifi` → saisir le code → jouer de la
musique. Le flux est mixé dans MASTER (le knob agit dessus) ; aucune fréquence ni aucun
codec n'est imposé au téléphone (SBC, AAC, aptX, LDAC… selon le téléphone). Une fois
jumelé, il est marqué « de confiance » et se reconnecte seul.

**Pourquoi le téléphone demande-t-il un code ?** Les téléphones jumellent normalement
*sans* code (« Secure Simple Pairing » : simple confirmation). Pour imposer un code,
le service `audio-hub-bluetooth` passe le contrôleur de la Pi en jumelage **classique
par code PIN**, et refuse toute demande de jumelage sans code. Contrepartie : un code
à 4 chiffres est moins robuste que le jumelage moderne ; suffisant pour une enceinte de
salon, mais choisissez un code plus long si des voisins sont à portée.

**Défaut du noyau contourné.** Un téléphone Android vérifie le code *pendant*
l'établissement de la connexion ; le noyau Linux (constaté en 6.18) abandonne alors
cette connexion sans la fermer, et le téléphone finit par effacer le jumelage. Le
service le détecte (comme `btmon`) et coupe lui-même la connexion orpheline : le
téléphone se reconnecte aussitôt avec la clé obtenue. Journal :
`… connexion abandonnée par le noyau juste après le jumelage … coupée`.

Gérer les téléphones jumelés :

```bash
sudo audio-hub status                       # section BLUETOOTH : téléphones connectés, codec
bluetoothctl devices Paired                  # téléphones jumelés
sudo bluetoothctl remove AA:BB:CC:DD:EE:FF   # en oublier un (il devra ressaisir le code)
sudo journalctl -u audio-hub-bluetooth -f    # jumelages, refus
```

Changer le code ne concerne que les **nouveaux** jumelages. Un téléphone jumelé
*avant* la mise en place du code (jumelage sans code) ne se reconnecte plus : l'oublier
des deux côtés (`bluetoothctl remove …` et dans les réglages du téléphone), puis le
rejumeler avec le code.

## 4. Mopidy

- Web : `http://hifi.local:6680/` (Iris) ; MPD : `hifi.local:6600` (MALP, Cantata, ncmpcpp…).
- Bibliothèque : backend **file** (navigation directe dans `/media`, toujours à jour) et
  **local** (recherche par artiste/album).
- Réindexation : une unité systemd *path* surveille `/media` ; dès qu'un dossier y
  apparaît ou disparaît (disque branché/débranché), la bibliothèque est réindexée, et
  aussi toutes les `scan-interval-minutes`. Peu importe ce qui remplit `/media`
  (pi-data-server, fstab, montage manuel) : aucun lien avec un autre module.
- Sortie : `pipewiresink target-object=MASTER` → Mopidy passe par MASTER comme le reste.
- Format fixe (`fixed-format = yes`, défaut) : Mopidy convertit chaque morceau en
  32 bits flottants à la fréquence de MASTER (192 kHz) avant PipeWire. Le format de sa
  sortie ne change donc jamais entre deux morceaux ; sans cela, l'enchaînement d'un
  fichier 44,1 kHz et d'un fichier 96 kHz (ou 16 / 24 bits) pouvait donner un son haché
  et suraigu ou un souffle, jusqu'à ce qu'on relance la lecture.
- Accessible uniquement depuis le réseau local (pare-feu).

## 5. Commandes utiles

```bash
sudo audio-hub status
sudo audio-hub list
sudo runuser -u hifi -- env XDG_RUNTIME_DIR=/run/user/$(id -u hifi) wpctl status
sudo journalctl _UID=$(id -u hifi) --user-unit=pipewire --user-unit=wireplumber -f
sudo journalctl _UID=$(id -u hifi) --user-unit=audio-hub-knob --user-unit=mopidy -f
sudo systemctl --user -M hifi@ restart wireplumber
cat /proc/asound/card*/stream0          # fréquence réellement négociée avec les appareils USB
cat /proc/asound/card*/pcm0p/sub0/hw_params   # idem pour le HAT (rate: 192000 attendu)
```

## 6. Recette (à faire une fois après installation)

1. `sudo audio-hub status` : MASTER présent, `amp` PRÉSENTE, liens `MASTER → hub.out.amp`.
2. Lire un fichier depuis Iris : son sur le HAT.
3. Allumer le DAC : il apparaît dans `status` et joue en même temps, sans coupure du HAT.
4. Éteindre le DAC en pleine lecture : le HAT continue.
5. Poser le diamant : la platine sort sur toutes les sorties ; `hw_params` / `stream0`
   indiquent 192000 Hz pour la platine.
6. Lancer du son sur le PC : il se mélange à la platine.
7. Éteindre le PC, puis la platine, puis les rallumer : raccordement automatique.
8. Tourner le knob : le volume de **tout** varie ; redémarrer la Pi : volume restauré.
9. Bluetooth : jumeler un téléphone (code demandé), jouer : son mêlé aux autres sources ;
   un code faux est refusé.

## 7. Dépannage

### Son « robotique » sur l'entrée S/PDIF : PC → adaptateur S/PDIF USB → Raspberry Pi

**Scénario** : le son d'un PC sort par sa sortie optique (*« Audio interne — Stéréo
numérique IEC958 »* sous Kubuntu), passe par la fibre optique vers l'adaptateur USB
**HiFimeDIY UR23 USB SPDIF Rx** branché sur la Pi, puis dans MASTER. La platine et
Mopidy sonnent bien, mais le son du PC est haché, métallique, « robotique ».

**Cause** : un récepteur S/PDIF comme l'UR23 ne convertit pas la fréquence : il livre
les échantillons au rythme du signal reçu, et la Pi doit l'ouvrir **exactement à cette
fréquence**. L'UR23 (USB Audio Class 1) ne permet pas à la Pi de lire la fréquence
entrante : elle est donc fixée dans `[input.spdif] rate = 96000`. Si le PC envoie du
48 kHz (réglage par défaut de PipeWire sur un PC), les deux ne correspondent pas et
aucun rééchantillonnage côté Pi ne peut corriger ce décalage. (Le rééchantillonnage
96 → 192 kHz vers MASTER, lui, est fait automatiquement.)

**Diagnostic** — sur le PC, pendant la lecture :

```bash
grep -H -E 'rate|format' /proc/asound/card*/pcm*p/sub0/hw_params
#   rate: 48000 (48000/1)   ← différent de la Pi : son robotique
```

**Solution** — régler le PC sur la même fréquence que la Pi, en permanence. Kubuntu
(PipeWire), en tant qu'utilisateur, sans sudo :

```bash
mkdir -p ~/.config/pipewire/pipewire.conf.d
cat > ~/.config/pipewire/pipewire.conf.d/50-96khz.conf <<'EOF'
# Toute la sortie audio du PC à 96 kHz (S/PDIF vers la Raspberry Pi)
context.properties = {
    default.clock.rate          = 96000
    default.clock.allowed-rates = [ 96000 ]
}
EOF
systemctl --user restart pipewire pipewire-pulse wireplumber
```

Revérifier : `rate: 96000 (96000/1)`. Tout ce que joue le PC (44,1 / 48 kHz…) est
alors converti en 96 kHz par le PC avant de partir sur la fibre. Pour annuler :
supprimer ce fichier et relancer la même commande `systemctl`.

Autres points :

- Choisir une autre fréquence est possible, à condition de mettre **la même** des deux
  côtés (`rate =` dans `[input.spdif]` puis `sudo audio-hub apply`). L'UR23 accepte
  32 ; 44,1 ; 48 ; 88,2 et 96 kHz.
- **Niveau** : le S/PDIF est numérique, son niveau dépend du volume de la sortie sur le
  PC : la mettre à **100 %**, et régler l'écoute avec le knob (MASTER).
- Si la fréquence est bonne et que le son reste haché : décrochages de l'adaptateur
  (périphérique USB lent) → `period-size = 1024` et `headroom = 2048` dans
  `[input.spdif]`, puis `sudo audio-hub apply`. `sudo audio-hub diag` (colonne ERR de
  `pw-top`) permet de le vérifier.

### Autres symptômes

| Symptôme | Piste |
|---|---|
| `MASTER ABSENT` | `sudo journalctl -b _SYSTEMD_USER_UNIT=pipewire.service` : erreur de syntaxe ou module manquant |
| Doute général | `sudo audio-hub diag` : rapport complet dans `/tmp/audio-hub-diag.txt` |
| Un appareil USB ne revient pas après une coupure (hub USB réinitialisé, DAC rallumé) alors qu'il apparaît dans `aplay -l` | WirePlumber l'a laissé sur le profil « off » ; `audio-hub-links` le rallume seul en quelques secondes : `sudo journalctl -f _SYSTEMD_USER_UNIT=audio-hub-links.service` |
| Silence partout alors que tout est « running » | une entrée absente reliée à MASTER : `systemctl --user -M hifi@ status audio-hub-links`, `sudo audio-hub links once` |
| Appareil `absente` alors qu'il est branché | ses `match.*` ne correspondent pas : `sudo audio-hub list` |
| Craquements | `clock.quantum = 2048`, puis `period-size = 1024` / `headroom = 1024` sur l'appareil USB ; baisser `resample.quality` si le CPU sature (`top`) |
| Son robotique / haché sur le S/PDIF | fréquence du PC ≠ `rate` de `[input.spdif]` : voir la section ci-dessus |
| L'adaptateur S/PDIF provoque des erreurs quand le PC est éteint | dépend de sa puce ; essayer `period-size = 1024`, `headroom = 2048` ; il n'est jamais horloge maître |
| Une source beaucoup plus faible que les autres (platine…) | `gain-db = 6` (par exemple) dans sa section `[input.…]`, puis `sudo audio-hub apply` |
| Le knob ne semble rien faire | `sudo audio-hub volume watch` en le tournant ; sinon `sudo audio-hub diag` (test du knob, 10 s) |
| Tout est faible | MASTER est bas (25 % ≈ -36 dB au premier démarrage) : `sudo audio-hub volume 60%` |
| Pas de son du tout sur le HAT | `aplay -l` doit lister la carte ; sinon overlay `rpi-digiampplus,unmute_amp` dans `config.txt` |
| Volume trop faible sur un seul appareil | son volume matériel doit être à 100 % : `sudo audio-hub diag`, section « Mixeurs ALSA » ; sinon réglage propre de l'appareil (entrée, mode ligne/casque, son propre bouton de volume) |
| Bluetooth : la Pi n'apparaît pas sur le téléphone | `sudo audio-hub status`, `systemctl status audio-hub-bluetooth` ; `rfkill list` ; redémarrage demandé après `apply` ? ; `discoverable = yes` ? |
| Bluetooth : le téléphone ne demande pas de code, ou échoue à se jumeler | `sudo journalctl -u audio-hub-bluetooth -b` ; s'il était déjà jumelé : l'oublier des deux côtés et recommencer |
| Bluetooth : connecté mais pas de son | `sudo audio-hub status` (section BLUETOOTH) ; le flux doit être relié à MASTER : `pw-link -l` ; supprimer un ancien `~hifi/.config/wireplumber/wireplumber.conf.d/60-bluetooth.conf` réglé à la main |
| Mopidy ne voit pas un disque | `sudo systemctl --user -M hifi@ start mopidy-scan`, `sudo journalctl _UID=$(id -u hifi) --user-unit=mopidy-scan` |
