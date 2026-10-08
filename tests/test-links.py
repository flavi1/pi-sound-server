#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Test hors matériel du démon « audio-hub links » : une entrée n'est reliée à
# MASTER que lorsque sa capture tourne ; déliée dès qu'elle disparaît.
# (Défaut corrigé : une boucle d'entrée absente rendait tout MASTER muet.)
import importlib.machinery, importlib.util, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = 0


def check(cond, msg):
    global FAILS
    print("  %s : %s" % ("ok  " if cond else "FAIL", msg))
    if not cond:
        FAILS += 1
        if os.environ.get("GITHUB_ACTIONS"):
            print("::error title=test-links::%s" % msg)


os.environ["AUDIO_HUB_CONF"] = os.path.join(HERE, "..", "audio-hub.conf")
path = os.path.join(HERE, "..", "files", "bin", "audio-hub")
loader = importlib.machinery.SourceFileLoader("audio_hub", path)
spec = importlib.util.spec_from_loader("audio_hub", loader)
ah = importlib.util.module_from_spec(spec)
loader.exec_module(ah)
c = ah.Config()

# --- configuration générée : plus de lien automatique des boucles -----------------
pw = ah.gen_pipewire(c)
check(pw.count("node.autoconnect = false") == len([d for d in c.inputs if d.enabled]),
      "chaque boucle d'entrée : node.autoconnect = false (pas de lien automatique)")
check('target.object = "MASTER"' not in pw, "plus de target.object MASTER sur les boucles")

# --- faux graphe -------------------------------------------------------------------
STATE = {}
CMDS = []


def graph():
    nodes, ports, links = {}, {}, []
    nid = 100
    pid = 1000
    nodes["MASTER"] = {"id": 1, "state": "running"}
    for ch in ("FL", "FR"):
        ports[pid] = (1, "playback_" + ch, "input"); pid += 1
    for inp, st in STATE.items():
        play, cap = nid, nid + 1
        nid += 10
        nodes["hub.loop.%s.playback" % inp] = {"id": play, "state": "running"}
        nodes["hub.loop.%s.capture" % inp] = {"id": cap, "state": st["cap"]}
        if st["dev"]:
            nodes["hub.in.%s" % inp] = {"id": nid + 5, "state": "running"}
        for ch in ("FL", "FR"):
            ports[pid] = (play, "output_" + ch, "output")
            if st["linked"]:
                links.append((play, pid, 1, 1000 if ch == "FL" else 1001))
            pid += 1
    return nodes, ports, links


class R:
    returncode = 0
    stdout = ""


def fake_as_user(c, cmd, check=False, capture=True):
    CMDS.append(cmd)
    return R()


ah.pw_graph = lambda c, objs=None: graph()
ah.as_user = fake_as_user
ah.log = lambda m: None

print("== platine absente (capture en veille), S/PDIF présent")
STATE.update({"turntable": {"cap": "suspended", "dev": False, "linked": False},
              "spdif": {"cap": "running", "dev": True, "linked": False}})
CMDS.clear(); ah.links_step(c)
check(not any("hub.loop.turntable.playback" in " ".join(x) for x in CMDS),
      "platine absente : jamais reliée à MASTER")
check(sum(1 for x in CMDS if x[0] == "pw-link" and "hub.loop.spdif.playback:output_FL" in x) == 1
      and sum(1 for x in CMDS if x[0] == "pw-link" and "hub.loop.spdif.playback:output_FR" in x) == 1,
      "S/PDIF actif : relié (FL et FR)")

print("== la platine apparaît et sa capture démarre")
STATE["spdif"]["linked"] = True
STATE["turntable"].update({"cap": "running", "dev": True})
CMDS.clear(); ah.links_step(c)
check([x for x in CMDS if "-d" not in x and "hub.loop.turntable.playback:output_FL" in x],
      "platine active : reliée")
check(not any("hub.loop.spdif" in " ".join(x) for x in CMDS), "S/PDIF déjà relié : rien à refaire")

print("== la platine est éteinte")
STATE["turntable"].update({"cap": "suspended", "dev": False, "linked": True})
CMDS.clear(); ah.links_step(c)
check(len([x for x in CMDS if x[:2] == ["pw-link", "-d"]]) == 2, "platine absente : déliée (2 liens)")

print("== appareil USB revenu sur le profil « off » (hub réinitialisé)")


def dev(i, bus, cur, profiles, api="alsa"):
    return {"id": i, "type": "PipeWire:Interface:Device",
            "info": {"props": {"device.api": api, "device.bus": bus, "device.description": "dev%d" % i},
                     "params": {"Profile": [{"index": cur[0], "name": cur[1]}],
                                "EnumProfile": [dict(index=x[0], name=x[1], priority=x[2], available=x[3])
                                                for x in profiles]}}}


PROFS = [(0, "off", 0, "yes"), (1, "output:analog-stereo", 6500, "yes"), (2, "pro-audio", 1, "yes")]
objs = [dev(145, "usb", (0, "off"), PROFS),                       # DAC revenu éteint
        dev(146, "usb", (1, "output:analog-stereo"), PROFS),      # déjà actif
        dev(59, "platform", (0, "off"), PROFS),                   # audio interne : non USB
        dev(147, "usb", (0, "off"), [(0, "off", 0, "yes"), (1, "output:x", 10, "no")])]  # rien d'utilisable
CMDS.clear(); last = {}
ah.profiles_step(c, objs, last, now=1000.0)
check(CMDS == [], "appareil qui vient d'apparaître : WirePlumber choisit d'abord (pas d'intervention)")
ah.profiles_step(c, objs, last, now=1005.0)
check(CMDS == [], "toujours rien avant %g s" % ah.OFF_GRACE)
ah.profiles_step(c, objs, last, now=1009.0)
check(CMDS == [["wpctl", "set-profile", "145", "1"]],
      "resté « off » : seul le DAC USB est rallumé, sur le profil normal (pas pro-audio) : %s" % CMDS)
CMDS.clear(); ah.profiles_step(c, objs, last, now=1012.0)
check(CMDS == [], "pas de nouvelle tentative avant 10 s")
CMDS.clear(); ah.profiles_step(c, [], last, now=1013.0)
ah.profiles_step(c, objs, last, now=1014.0)
check(CMDS == [], "appareil reparti puis revenu : nouveau délai de grâce")

PRO_FIRST = [(0, "off", 0, "yes"), (2, "pro-audio", 9000, "yes"), (1, "output:analog-stereo", 6500, "unknown")]
check(ah.best_profile(dev(150, "usb", (0, "off"), PRO_FIRST)) == (1, "output:analog-stereo"),
      "profil normal préféré à pro-audio, même de priorité plus faible")
check(ah.best_profile(dev(151, "usb", (0, "off"), [(0, "off", 0, "yes"), (2, "pro-audio", 1, "yes")])) == (2, "pro-audio"),
      "pro-audio seulement en dernier recours")

print("== état d'une sortie revenue (journal)")
d_dac = next(d for d in c.outputs if d.id == "dac")
snap_objs = [
    {"id": 145, "type": "PipeWire:Interface:Device", "info": {"params": {"Profile": [{"name": "output:analog-stereo"}]}}},
    {"id": 118, "type": "PipeWire:Interface:Node", "info": {"state": "running", "props": {"node.name": "hub.out.dac", "device.id": 145}}},
    {"id": 120, "type": "PipeWire:Interface:Node", "info": {"state": "running", "props": {"node.name": "output.MASTER_hub.out.dac"},
                                                             "params": {"Props": [{"channelVolumes": [1.0, 1.0], "mute": False}]}}},
    {"id": 300, "type": "PipeWire:Interface:Link", "info": {"output-node-id": 120, "input-node-id": 118}},
    {"id": 301, "type": "PipeWire:Interface:Link", "info": {"output-node-id": 120, "input-node-id": 118}}]
snap = ah.output_snapshot(c, snap_objs, d_dac)
check(snap == "sortie dac : profil=output:analog-stereo état=running ; flux de MASTER : état=running volume=1.00,1.00 muet=False liens=2",
      "résumé : %s" % snap)
check("ABSENT" in ah.output_snapshot(c, snap_objs[:2], d_dac), "flux de MASTER manquant signalé")

print("== format des flux (audio-hub status)")
objs = [{"type": "PipeWire:Interface:Node", "info": {"state": "running",
         "props": {"media.class": "Stream/Output/Audio", "application.name": "Mopidy"},
         "params": {"Format": [{"format": "F32LE", "rate": 192000, "channels": 2}]}}},
        {"type": "PipeWire:Interface:Node", "info": {"state": "running",
         "props": {"media.class": "Audio/Sink", "node.name": "MASTER"}, "params": {}}}]
check(ah.stream_formats(objs) == [("Mopidy", "running", "F32LE 192000 Hz 2 canaux")],
      "Mopidy : format négocié affiché, MASTER ignoré")

print()
print("%d échec(s)" % FAILS)
sys.exit(1 if FAILS else 0)
