#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Test hors matériel du knob : faux module evdev reproduisant une vraie Pi
# (entrées HDMI-CEC vc4-hdmi + knob USB JONSBO à 4 interfaces).
#   - « auto » ne doit retenir QUE l'interface USB qui a les touches de volume ;
#   - les événements Volume+/Volume- doivent modifier MASTER.
import importlib.machinery, importlib.util, os, sys, types

HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = 0


def check(cond, msg):
    global FAILS
    print("  %s : %s" % ("ok  " if cond else "FAIL", msg))
    if not cond:
        FAILS += 1
        if os.environ.get("GITHUB_ACTIONS"):
            print("::error title=test-knob::%s" % msg)


# --- faux evdev --------------------------------------------------------------
ec = types.SimpleNamespace(EV_KEY=1, EV_REL=2, KEY_VOLUMEUP=115, KEY_VOLUMEDOWN=114,
                           KEY_MUTE=113, KEY_A=30, KEY_PLAYPAUSE=164, KEY_PLAY=207,
                           KEY_PAUSE=119, KEY_ENTER=28, BTN_LEFT=272, BTN_0=256,
                           REL_DIAL=7, REL_WHEEL=8)
VOL = [114, 115]
DEVICES = {
    "/dev/input/event5": ("vc4-hdmi-1", "vc4-hdmi/input0", {1: VOL + [30], 2: [0, 1]}),
    "/dev/input/event4": ("vc4-hdmi-0", "vc4-hdmi/input0", {1: VOL, 2: [0, 1]}),
    "/dev/input/event3": ("JONSBO JONSBO  Volume Control Consumer Control",
                          "usb-0000:01:00.0-1.2.2/input1", {1: VOL + [113, 164]}),
    "/dev/input/event2": ("JONSBO JONSBO  Volume Control System Control",
                          "usb-0000:01:00.0-1.2.2/input1", {1: [142, 143]}),
    "/dev/input/event1": ("JONSBO JONSBO  Volume Control Mouse",
                          "usb-0000:01:00.0-1.2.2/input1", {1: [272], 2: [0, 1, 8]}),
    "/dev/input/event0": ("JONSBO JONSBO  Volume Control",
                          "usb-0000:01:00.0-1.2.2/input0", {1: VOL + [30, 31, 32]}),
}
EVENTS = {"/dev/input/event3": [(1, 115, 1), (1, 115, 0), (1, 115, 1), (1, 114, 1), (1, 113, 1)]}
FDS = {}


class Ev:
    def __init__(self, t, c, v):
        self.type, self.code, self.value = t, c, v


class InputDevice:
    def __init__(self, path):
        self.path = path
        self.name, self.phys, self._caps = DEVICES[path]
        self.fd = 100 + int(path[-1])
        FDS[self.fd] = path
        self.grabbed = False

    def capabilities(self):
        return self._caps

    def grab(self):
        self.grabbed = True

    def close(self):
        pass

    def read(self):
        evs = EVENTS.pop(self.path, [])
        return [Ev(*x) for x in evs]


fake = types.ModuleType("evdev")
fake.list_devices = lambda: list(DEVICES)
fake.InputDevice = InputDevice
fake.ecodes = ec
sys.modules["evdev"] = fake

# --- chargement d'audio-hub comme module ------------------------------------------
os.environ["AUDIO_HUB_CONF"] = os.path.join(HERE, "..", "audio-hub.conf")
path = os.path.join(HERE, "..", "files", "bin", "audio-hub")
loader = importlib.machinery.SourceFileLoader("audio_hub", path)
spec = importlib.util.spec_from_loader("audio_hub", loader)
ah = importlib.util.module_from_spec(spec)
loader.exec_module(ah)

print("== sélection automatique")
cands = ah.knob_candidates()
paths = [t[1] for t in cands]
check("/dev/input/event4" not in paths and "/dev/input/event5" not in paths,
      "entrées HDMI-CEC (vc4-hdmi) ignorées")
c = ah.Config()
wanted = ah.knob_wanted_paths(c)
check(wanted == ["/dev/input/event3"], "auto => uniquement l'interface « Consumer Control » (%s)" % wanted)

print("== événements -> volume MASTER")
calls = []


class FakeMaster:
    def __init__(self, c):
        pass

    def change(self, d):
        calls.append(round(d, 3))

    def toggle_mute(self):
        calls.append("mute")

    def maybe_save(self):
        if not EVENTS:
            raise StopIteration


ah.Master = FakeMaster
ah.select.select = lambda r, w, x, t=None: ([fd for fd in r if FDS.get(fd) in EVENTS], [], [])
try:
    ah.cmd_knob(c)
except StopIteration:
    pass
step = float(c.knob["step"])
check(calls == [step, step, -step, "mute"], "Volume+ ×2 (répétition comprise), Volume-, Mute : %s" % calls)

print()
print("%d échec(s)" % FAILS)
sys.exit(1 if FAILS else 0)
