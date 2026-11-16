"""Workflow-owned Python launches never write bytecode into the interpreter tree.

The shared managed runtime is verified file-for-file; one __pycache__ written
into it fails verification and forces a new runtime generation. Every case
strips the caller's Python environment so a defect cannot be masked by the
test runner's own PYTHONDONTWRITEBYTECODE/PYTHONUTF8.
"""
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
RUNTIME = REPO / ".agents/skills/itl-remote-runner/scripts"
sys.path.insert(0, str(RUNTIME))
from itl_remote import common, transport

PROBE = """import json, subprocess, sys
sys.path.insert(0, sys.argv[1])
import launch_probe_child
grandchild = subprocess.run([sys.executable, "-c",
    "import sys; sys.path.insert(0, sys.argv[1]); import launch_probe_grandchild; "
    "print(int(sys.flags.dont_write_bytecode), int(sys.flags.utf8_mode))", sys.argv[1]],
    stdout=subprocess.PIPE, check=True)
flags = grandchild.stdout.decode("ascii").split()
print(json.dumps({"child": [int(sys.flags.dont_write_bytecode), int(sys.flags.utf8_mode)],
                  "grandchild": [int(value) for value in flags]}))
"""


def clean_environment():
    return {key: value for key, value in os.environ.items() if not key.upper().startswith("PYTHON")}


class PythonLaunchContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        # Whitespace and Cyrillic in one exact path, as user-controlled roots are.
        self.modules = Path(self.temporary.name) / "Модули с пробелом"
        self.modules.mkdir()
        for name in ("launch_probe_child", "launch_probe_grandchild"):
            (self.modules / (name + ".py")).write_text("VALUE = 1\n", encoding="utf-8")
        self.probe = self.modules / "probe.py"
        self.probe.write_text(PROBE, encoding="utf-8")

    def tearDown(self):
        self.temporary.cleanup()

    def bytecode(self):
        return sorted(str(path.relative_to(self.modules)) for path in self.modules.rglob("*.pyc"))

    def test_uncontracted_launch_is_detected(self):
        with patch.dict(os.environ, clean_environment(), clear=True):
            subprocess.run([sys.executable, str(self.probe), str(self.modules)], stdout=subprocess.PIPE, check=True)
        self.assertTrue(self.bytecode(), "fixture must observe bytecode from a raw launch")

    def test_python_command_and_native_environment_cover_children_and_grandchildren(self):
        with patch.dict(os.environ, clean_environment(), clear=True):
            completed = subprocess.run(common.python_command(self.probe, self.modules), env=common.native_environment(),
                                       stdout=subprocess.PIPE, check=True)
        self.assertEqual({"child": [1, 1], "grandchild": [1, 1]}, json.loads(completed.stdout))
        self.assertEqual([], self.bytecode())

    def test_ssh_rpc_bootstrap_applies_the_contract_in_a_fresh_remote_session(self):
        calls = []

        def remote_session(command, *, input_bytes, timeout):
            calls.append(command)
            encoded = command[command.index("-EncodedCommand") + 1]
            # A remote sshd session never inherits the controller's environment.
            completed = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
                                       input=input_bytes, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       env=clean_environment(), timeout=timeout)
            self.assertEqual(0, completed.returncode, completed.stderr.decode("utf-8", errors="replace"))
            return completed.stdout

        rpc = self.modules / "rpc.py"
        rpc.write_text("import json, sys\nsys.path.insert(0, " + repr(str(self.modules)) + ")\n"
                       "import launch_probe_child\nsys.stdin.read()\n"
                       "print(json.dumps({'flags': [int(sys.flags.dont_write_bytecode), int(sys.flags.utf8_mode)], "
                       "'argv': sys.argv[1:]}))\n", encoding="utf-8")
        profile = {"transport": "ssh", "ssh": {"host": "worker", "python": sys.executable, "runtime": str(rpc),
                                               "spool": str(self.modules / "spool")}}
        with patch.object(transport, "capture", remote_session):
            response = transport.Connection(profile).call({"operation": "probe"})
        self.assertEqual(1, len(calls))
        self.assertEqual({"flags": [1, 1], "argv": ["rpc", "--spool", str(self.modules / "spool")]}, response)
        self.assertEqual([], self.bytecode())

    def test_runner_sources_launch_python_only_through_the_shared_contract(self):
        offenders = []
        for path in sorted(RUNTIME.rglob("*.py")):
            text = path.read_text(encoding="utf-8")
            relative = path.relative_to(RUNTIME).as_posix()
            if re.search(r"\[\s*sys\.executable\b", text):
                offenders.append(relative + ": argv starts with sys.executable; use common.python_command")
            if relative != "itl_remote/common.py" and re.search(r"[\"']-B[\"']\s*,\s*[\"']-X[\"']", text):
                offenders.append(relative + ": interpreter flags spelled per caller")
        self.assertEqual([], offenders)


if __name__ == "__main__":
    unittest.main()
