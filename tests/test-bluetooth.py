#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Test hors matériel de l'agent Bluetooth (faux D-Bus, fausse interface mgmt) :
#  - le code PIN répondu est celui de la configuration ;
#  - tout jumelage SANS code (confirmation, « just works », passkey) est refusé ;
#  - un service n'est autorisé que pour un appareil jumelé ;
#  - le contrôleur est passé en jumelage par code PIN (SSP coupé) et en « haut-parleur »,
#    via l'interface mgmt du noyau (btmgmt se bloque sans terminal).
import importlib.machinery, importlib.util, os, sys, types

HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = 0


def check(cond, msg):
    global FAILS
    print("  %s : %s" % ("ok  " if cond else "FAIL", msg))
    if not cond:
        FAILS += 1
        if os.environ.get("GITHUB_ACTIONS"):
            print("::error title=test-bluetooth::%s" % msg)


os.environ["AUDIO_HUB_CONF"] = os.path.join(HERE, "..", "audio-hub.conf")
path = os.path.join(HERE, "..", "files", "bin", "audio-hub")
loader = importlib.machinery.SourceFileLoader("audio_hub", path)
spec = importlib.util.spec_from_loader("audio_hub", loader)
ah = importlib.util.module_from_spec(spec)
loader.exec_module(ah)
ah.log = lambda m: None
c = ah.Config()

# --- faux module dbus ----------------------------------------------------------------
class FakeDBusException(Exception):
    _dbus_error_name = None


class FakeObject:
    def __init__(self, bus, path):
        self.path = path


fake = types.SimpleNamespace(
    DBusException=FakeDBusException,
    service=types.SimpleNamespace(Object=FakeObject, method=lambda *a, **k: (lambda f: f)))

PAIRED = {"/org/bluez/hci0/dev_AA": True, "/org/bluez/hci0/dev_BB": False}
agent = ah.bt_make_agent(fake, None, c.bt["pin"], lambda d: d, lambda d: PAIRED.get(d, False))


def rejected(fn, *a):
    try:
        fn(*a)
    except FakeDBusException as ex:
        return getattr(ex, "_dbus_error_name", None) == "org.bluez.Error.Rejected"
    return False


print("== agent")
check(agent.path == ah.AGENT_PATH, "objet exporté sur %s" % ah.AGENT_PATH)
check(agent.RequestPinCode("/org/bluez/hci0/dev_BB") == "1234", "code PIN répondu : celui de la config (1234)")
a2 = ah.bt_make_agent(fake, None, "98765", str, lambda d: False)
check(a2.RequestPinCode("/x") == "98765", "code PIN modifié dans la config : pris en compte")
check(rejected(agent.RequestConfirmation, "/org/bluez/hci0/dev_BB", 123456),
      "confirmation numérique (sans code) refusée")
check(rejected(agent.RequestAuthorization, "/org/bluez/hci0/dev_BB"), "« just works » (sans code) refusé")
check(rejected(agent.RequestPasskey, "/org/bluez/hci0/dev_BB"), "passkey SSP refusée")
check(agent.AuthorizeService("/org/bluez/hci0/dev_AA", "0000110b-0000-1000-8000-00805f9b34fb") is None,
      "service A2DP autorisé pour un appareil jumelé")
check(rejected(agent.AuthorizeService, "/org/bluez/hci0/dev_BB", "0000110b-0000-1000-8000-00805f9b34fb"),
      "service refusé pour un appareil non jumelé")

print("== contrôleur (interface mgmt du noyau)")
import struct
raw = (b"\xaa" * 6 + b"\x09" + struct.pack("<H", 305) + struct.pack("<I", 0xffff)
       + struct.pack("<I", 0x1 | 0x10 | 0x40 | 0x80 | 0x200 | 0x800) + (0x6c0000).to_bytes(3, "little")
       + b"hifi".ljust(249, b"\0") + b"\0" * 11)
inf = ah.mgmt_parse_info(raw)
check(inf["settings"] == {"powered", "bondable", "ssp", "br/edr", "le", "secure-conn"}
      and inf["class"] == 0x6c0000, "lecture des réglages du contrôleur : %s" % sorted(inf["settings"]))


class FakeMgmt:
    def __init__(self):
        self.calls = []
        self.ssp, self.cls = True, 0x6c0000

    def info(self, index):
        self.calls.append(("info",))
        return {"settings": {"powered", "ssp"} if self.ssp else {"powered"}, "class": self.cls}

    def set(self, op, index, *vals):
        self.calls.append((op,) + vals)
        if op == ah.MGMT_SET_SSP:
            self.ssp = bool(vals[0])
        if op == ah.MGMT_SET_CLASS:
            self.cls = 0x6c0000 | (vals[0] << 8) | vals[1]
        return 0


fm = FakeMgmt()
ah.bt_controller_fix(fm, 0)
order = [x for x in fm.calls if x != ("info",)]
check(order[:4] == [(ah.MGMT_SET_POWERED, 0), (ah.MGMT_SET_SC, 0), (ah.MGMT_SET_SSP, 0),
                    (ah.MGMT_SET_POWERED, 1)],
      "SSP coupé contrôleur éteint, puis rallumé")
check((ah.MGMT_SET_CLASS, 4, 20) in fm.calls and (fm.cls & 0x1ffc) == 0x0414, "classe « haut-parleur »")
fm.calls.clear()
ah.bt_controller_fix(fm, 0)
check(fm.calls == [("info",)], "déjà correct : aucune extinction ni modification")

print()
print("%d échec(s)" % FAILS)
sys.exit(1 if FAILS else 0)
