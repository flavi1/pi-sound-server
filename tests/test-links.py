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
check(pw.count("node.autoconnect = false") == len([d for d in c.inputs + c.outputs if d.enabled]),
      "chaque boucle (entrées et sorties) : node.autoconnect = false (pas de lien automatique)")
check(pw.count('target.object = "MASTER"') == len([d for d in c.outputs if d.enabled]),
      "target.object MASTER : seulement sur la capture des boucles de sortie (moniteur), jamais vers MASTER")

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
    {"id": 120, "type": "PipeWire:Interface:Node", "info": {"state": "running", "props": {"node.name": "hub.master.dac.playback"},
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

print("== serveur son prêt ?")
def nd(name):
    return {"type": "PipeWire:Interface:Node", "info": {"props": {"node.name": name}}}
meta = {"type": "PipeWire:Interface:Metadata", "props": {"metadata.name": "default"},
        "metadata": [{"key": "default.audio.sink", "value": {"name": "MASTER"}}]}
units = {"audio-hub-init.service": True, "audio-hub-links.service": True, "mopidy.service": True}
ok, present, missing = ah.ready_check(c, [nd("MASTER"), nd("hub.out.amp"), meta], units, True)
check(ok and present == ["MASTER", "sorties amp", "Mopidy", "Bluetooth « %s »" % c.bt_name],
      "tout est prêt : %s" % present)
ok, present, missing = ah.ready_check(c, [nd("MASTER"), nd("hub.out.amp")], dict(units, **{"mopidy.service": False}), False)
check(not ok and missing == ["MASTER par défaut", "Mopidy", "Bluetooth"],
      "manques signalés : %s" % missing)

print("== sorties : boucle MASTER -> appareil")
OUT = {}


def graph_out():
    nodes, ports, links = {"MASTER": {"id": 1, "state": "running"}}, {}, []
    pid = 5000
    nid = 500
    for o, st in OUT.items():
        play = nid; nid += 10
        nodes["hub.master.%s.playback" % o] = {"id": play, "state": "running"}
        for ch in ("FL", "FR"):
            ports[pid] = (play, "output_" + ch, "output"); pid += 1
        if st["dev"]:
            dev = nid; nid += 10
            nodes["hub.out.%s" % o] = {"id": dev, "state": "running"}
            for ch in st.get("chans", ("FL", "FR")):
                ports[pid] = (dev, "playback_" + ch, "input"); pid += 1
            if st["linked"]:
                links.append((play, pid - 10, dev, pid - 1))
                links.append((play, pid - 9, dev, pid - 2))
        if st.get("wrong"):
            links.append((play, 1, 1, 2))           # relié à MASTER : interdit
    return nodes, ports, links


ah.pw_graph = lambda c, objs=None: graph_out() if OUT else graph()
STATE.clear()
OUT.update({"amp": {"dev": True, "linked": False}, "dac": {"dev": False, "linked": False}})
CMDS.clear(); ah.links_step(c)
check([x for x in CMDS if x == ["pw-link", "hub.master.amp.playback:output_FL", "hub.out.amp:playback_FL"]]
      and [x for x in CMDS if x == ["pw-link", "hub.master.amp.playback:output_FR", "hub.out.amp:playback_FR"]],
      "amp présent : sa boucle est reliée FL->FL, FR->FR")
check(not any("dac" in " ".join(x) for x in CMDS), "DAC absent : rien n'est relié")
OUT["dac"] = {"dev": True, "linked": False, "chans": ("AUX0", "AUX1")}
OUT["amp"]["linked"] = True
CMDS.clear(); ah.links_step(c)
check(CMDS == [["pw-link", "hub.master.dac.playback:output_FL", "hub.out.dac:playback_AUX0"],
               ["pw-link", "hub.master.dac.playback:output_FR", "hub.out.dac:playback_AUX1"]],
      "DAC revenu (profil pro-audio) : relié FL->AUX0, FR->AUX1 ; amp déjà relié, intact : %s" % CMDS)
OUT["dac"] = {"dev": False, "linked": False, "wrong": True}
CMDS.clear(); ah.links_step(c)
check(CMDS == [["pw-link", "-d", "1", "2"]], "boucle d'une sortie reliée ailleurs (MASTER) : déliée aussitôt")
OUT.clear()

print("== sentinelle : PipeWire figé")
clk = [0.0]
hw = ah.HangWatch(clock=lambda: clk[0])
check(not hw.step(False, True), "première absence de réponse : on attend")
clk[0] = 30; check(not hw.step(False, True), "30 s : on attend encore")
clk[0] = 61; check(hw.step(False, True), "plus de 60 s sans réponse : relance")
clk[0] = 200; hw.step(False, True); clk[0] = 270
check(not hw.step(False, True), "pas plus d'une relance toutes les 5 min")
hw2 = ah.HangWatch(clock=lambda: clk[0])
clk[0] = 0; hw2.step(False, False); clk[0] = 100
check(not hw2.step(False, False), "PipeWire arrêté (systemd s'en charge) : pas de relance")
clk[0] = 0; hw3 = ah.HangWatch(clock=lambda: clk[0]); hw3.step(False, True); clk[0] = 50; hw3.step(True, True); clk[0] = 90
check(not hw3.step(False, True), "répond de nouveau entre-temps : compteur remis à zéro")

print()
print("%d échec(s)" % FAILS)
sys.exit(1 if FAILS else 0)
