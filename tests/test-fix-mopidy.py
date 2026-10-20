#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Test du correctif de mopidy/audio/scan.py (GStreamer 1.26.2, StructureWrapper)
import importlib.machinery, importlib.util, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = 0


def check(cond, msg):
    global FAILS
    print("  %s : %s" % ("ok  " if cond else "FAIL", msg))
    if not cond:
        FAILS += 1
        if os.environ.get("GITHUB_ACTIONS"):
            print("::error title=test-fix-mopidy::%s" % msg)


path = os.path.join(HERE, "..", "files", "bin", "audio-hub-fix-mopidy")
loader = importlib.machinery.SourceFileLoader("fixm", path)
spec = importlib.util.spec_from_loader("fixm", loader)
fx = importlib.util.module_from_spec(spec)
loader.exec_module(fx)

SCAN = (
    "def _process(pipeline, timeout_ms):\n"
    "    while True:\n"
    "        if msg.get_structure().get_name() == \"have-type\":\n"
    "            mime = msg.get_structure().get_value(\"caps\").get_name()\n"
    "            if mime.startswith(\"text/\"):\n"
    "                return\n"
)
new, changed, known = fx.patch_text(SCAN)
check(changed and known and fx.OLD not in new and fx.NEW in new, "ligne fautive remplacée")
check(fx.patch_text(new) == (new, False, True), "idempotent")
check(fx.patch_text("autre chose") == ("autre chose", False, False), "fichier inconnu : non modifié")

ns = {}
exec(compile(new[new.index(fx.MARK):], "scan", "exec"), ns)
f = ns["_pi_struct_name"]


class Structure:
    def get_name(self):
        return "audio/mpeg"


class Wrapper:                       # GStreamer 1.26.2
    def __init__(self):
        self._StructureWrapper__structure = Structure()


class Odd:
    def __str__(self):
        return "audio/x-flac, framed=(boolean)true"


check(f(Structure()) == "audio/mpeg", "Gst.Structure classique")
check(f(Wrapper()) == "audio/mpeg", "StructureWrapper (GStreamer 1.26.2)")
check(f(Odd()) == "audio/x-flac", "repli : nom tiré du texte de la structure")

with tempfile.TemporaryDirectory() as d:
    p = os.path.join(d, "scan.py")
    with open(p, "w") as fh:
        fh.write(SCAN)
    sys.argv = ["x", "--quiet", p]
    fx.main()
    with open(p) as fh:
        check(fx.MARK in fh.read(), "fichier corrigé sur disque")

print()
print("%d échec(s)" % FAILS)
sys.exit(1 if FAILS else 0)
