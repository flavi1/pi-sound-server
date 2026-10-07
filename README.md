# pi-sound-server

[![CI](https://github.com/flavi1/pi-sound-server/actions/workflows/ci.yml/badge.svg)](https://github.com/flavi1/pi-sound-server/actions/workflows/ci.yml)

Hub audio pour Raspberry Pi 4 / 5 sans bureau graphique : **toutes les entrées →
MASTER → toutes les sorties**, branchement / débranchement à chaud, knob USB pour le
volume global, Mopidy pour lire `/media`. Réseau local uniquement.

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
   `node.linger` : appareil absent → la boucle attend en silence (sans jamais se
   rabattre sur une autre entrée) ; appareil revenu → raccordée automatiquement.
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
  conservé).

Tout est réversible (`manage = no` puis `sudo audio-hub apply` restaure l'original),
une copie est gardée dans `config.txt.pi-sound-server.orig`, et le bloc radio de
pi-server n'est pas touché. Un changement demande un redémarrage (signalé à la
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
| `[input.<id>]` | mêmes clés + `volume` | gain de l'entrée dans MASTER (0..1) |
| `[boot]` | `manage`, `file`, `overlay`, `disable-onboard-audio`, `disable-hdmi-audio` | config.txt (voir plus haut) |
| `[mopidy]` | `http.port`, `mpd.port`, `media-dirs`, `iris`, `scan-interval-minutes` | |
| | `extra-codecs` | `no` : FLAC, MP3, OGG, Opus, WAV, AIFF. `yes` : + AAC/M4A/ALAC/WMA (ffmpeg, ≈ 300 Mo), puis relancer `install.sh` |

Ajouter un appareil = ajouter une section `[output.xxx]` ou `[input.xxx]`.

### Le knob

```bash
sudo audio-hub knob-list
# /dev/input/event3
#     nom : USB Volume Knob
#     chemin stable : /dev/input/by-id/usb-XXXX_USB_Volume_Knob-event-if00
```

Reportez le chemin stable dans `[knob] device = …` (ou laissez `auto`). Le démon gère
les touches Volume+/Volume−/Mute et les molettes (`REL_DIAL`), survit au débranchement
du knob, et mémorise le volume (restauré au redémarrage, plafonné à `master.max-volume`).

## 4. Mopidy

- Web : `http://hifi.local:6680/` (Iris) ; MPD : `hifi.local:6600` (MALP, Cantata, ncmpcpp…).
- Bibliothèque : backend **file** (navigation directe dans `/media`, toujours à jour) et
  **local** (recherche par artiste/album).
- Réindexation : une unité systemd *path* surveille `/media` ; dès qu'un dossier y
  apparaît ou disparaît (disque branché/débranché), la bibliothèque est réindexée, et
  aussi toutes les `scan-interval-minutes`. Peu importe ce qui remplit `/media`
  (pi-data-server, fstab, montage manuel) : aucun lien avec un autre module.
- Sortie : `pipewiresink target-object=MASTER` → Mopidy passe par MASTER comme le reste.
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

## 7. Dépannage

| Symptôme | Piste |
|---|---|
| `MASTER ABSENT` | `sudo journalctl _UID=$(id -u hifi) --user-unit=pipewire -b` : erreur de syntaxe ou module manquant |
| Appareil `absente` alors qu'il est branché | ses `match.*` ne correspondent pas : `sudo audio-hub list` |
| Craquements | `clock.quantum = 2048`, puis `period-size = 1024` / `headroom = 1024` sur l'appareil USB ; baisser `resample.quality` si le CPU sature (`top`) |
| L'adaptateur S/PDIF provoque des erreurs quand le PC est éteint | dépend de sa puce ; essayer `period-size = 1024`, `headroom = 2048` ; il n'est jamais horloge maître, le reste du système n'est pas affecté |
| Pas de son du tout sur le HAT | `aplay -l` doit lister la carte ; sinon overlay `rpi-digiampplus,unmute_amp` dans `config.txt` |
| Volume trop faible sur un appareil | son volume matériel : `wpctl set-volume <id> 1.0` (via la commande `runuser` ci-dessus) |
| Mopidy ne voit pas un disque | `sudo systemctl --user -M hifi@ start mopidy-scan`, `sudo journalctl _UID=$(id -u hifi) --user-unit=mopidy-scan` |
