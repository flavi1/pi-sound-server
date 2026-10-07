#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Test hors matériel de l'agent Bluetooth (faux D-Bus, faux btmgmt) :
#  - le code PIN répondu est celui de la configuration ;
#  - tout jumelage SANS code (confirmation, « just works », passkey) est refusé ;
#  - un service n'est autorisé que pour un appareil jumelé ;
#  - le contrôleur est passé en jumelage par code PIN (SSP coupé) et en « haut-parleur ».
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

print("== contrôleur (btmgmt)")
INFO_SSP = """hci0:	Primary controller
	addr DC:A6:32:00:00:00 version 9 manufacturer 305 class 0x6c0000
	supported settings: powered connectable fast-connectable discoverable bondable link-security ssp br/edr le advertising secure-conn debug-keys privacy static-addr phy-configuration
	current settings: powered bondable ssp br/edr le secure-conn
	name hifi
"""
inf = ah.mgmt_info(INFO_SSP)
check("ssp" in inf["settings"] and inf["class"] == 0x6c0000, "lecture de « btmgmt info »")

CALLS = []
STATE = {"ssp": True, "class": 0x6c0000}


def fake_mgmt(hci, *args):
    CALLS.append(args)
    if args == ("ssp", "off"):
        STATE["ssp"] = False
    if args[:1] == ("class",):
        STATE["class"] = 0x6c0000 | (int(args[1]) << 8) | int(args[2])
    if args == ("info",):
        t = INFO_SSP if STATE["ssp"] else INFO_SSP.replace(" ssp br/edr", " br/edr")
        return t.replace("class 0x6c0000", "class 0x%06x" % STATE["class"])
    return ""


ah.bt_mgmt = fake_mgmt
ah.bt_controller_fix("hci0")
order = [a for a in CALLS if a != ("info",)]
check(order[:4] == [("power", "off"), ("sc", "off"), ("ssp", "off"), ("power", "on")],
      "SSP coupé contrôleur éteint, puis rallumé : %s" % order[:4])
check(("class", "4", "20") in CALLS and (STATE["class"] & 0x1ffc) == 0x0414, "classe « haut-parleur »")
CALLS.clear()
ah.bt_controller_fix("hci0")
check(CALLS == [("info",)], "déjà correct : aucune extinction ni modification")

print()
print("%d échec(s)" % FAILS)
sys.exit(1 if FAILS else 0)
