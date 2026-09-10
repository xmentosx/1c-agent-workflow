"""Public stdio protocol and owned-client lifecycle; fixtures do not qualify live 1C."""
import os
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / ".agents/skills/itl-remote-runner/scripts"))
from itl_remote import vanessa
from itl_remote.common import WorkError, read_json, write_json


def result(text="- Статус: Success\n## Шаги (1)\n**Success**"):
    return {"content": [{"type": "text", "text": text}]}


class VanessaAdapterTests(unittest.TestCase):
    @unittest.skipUnless(os.name == 'nt', 'Windows PowerShell process boundary')
    def test_owned_windows_powershell_process_reconstructs_its_module_path(self):
        from itl_remote.common import OwnedProcess
        shell = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        with tempfile.TemporaryDirectory(prefix='Граница модулей PowerShell ') as directory:
            log = Path(directory) / 'result.json'
            command = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $proof=[Console]::In.ReadLine() | ConvertFrom-Json; @{version=$PSVersionTable.PSVersion.Major;modulePath=$env:PSModulePath;command=(Get-Command Get-FileHash -ErrorAction Stop).Name;privateInput=($proof.token.Length -eq 64)} | ConvertTo-Json -Compress"
            private_input = (json.dumps({'token': '7' * 64}) + '\n').encode('ascii')
            with patch.dict(os.environ, {'PSModulePath': 'PS7 incompatible modules'}):
                with OwnedProcess([str(shell), '-NoProfile', '-Command', command], directory, log, input_data=private_input) as process:
                    process.wait(10, lambda: False)
                self.assertEqual('PS7 incompatible modules', os.environ['PSModulePath'])
            observed = json.loads(log.read_text(encoding='utf-8-sig'))
            self.assertEqual(5, observed['version'])
            self.assertEqual('Get-FileHash', observed['command'])
            self.assertTrue(observed['privateInput'])
            self.assertNotIn('7' * 64, log.read_text(encoding='utf-8-sig'))
            self.assertNotIn('PS7 incompatible modules', observed['modulePath'])

    def test_windows_powershell_does_not_inherit_another_editions_module_path(self):
        from itl_remote.common import native_environment
        with patch.dict(os.environ, {"PSModulePath": "PS7 incompatible modules", "ITL_KEEP": "kept"}):
            child = native_environment(windows_powershell=True)
            self.assertNotIn("psmodulepath", {key.lower() for key in child})
            self.assertEqual("kept", child["ITL_KEEP"])
            self.assertEqual("PS7 incompatible modules", {k.lower(): v for k, v in native_environment().items()}["psmodulepath"])

    def test_stdio_handshake_unicode_progress_errors_and_owned_close(self):
        with tempfile.TemporaryDirectory(prefix="ITL адаптер с пробелом ") as directory:
            root = Path(directory)
            fixture = root / "фасад stdio.py"
            fixture.write_text('''import json, sys
initialized = False
for line in sys.stdin:
    q = json.loads(line)
    method = q['method']
    if method == 'notifications/initialized':
        initialized = True
        continue
    if method == 'initialize':
        value = {'protocolVersion': '2024-11-05', 'capabilities': {}}
    else:
        assert initialized and method == 'tools/call'
        p = q['params']
        assert p['name'] == 'call_tool'
        args = json.loads(p['arguments']['argumentsJson'])
        value = {'content': [{'type': 'text', 'text': args['path']}],
                 'isError': p['arguments']['name'] == 'fail'}
        print(json.dumps({'jsonrpc': '2.0', 'method': 'notifications/progress'}), flush=True)
    print(json.dumps({'jsonrpc': '2.0', 'id': q['id'], 'result': value}), flush=True)
''', encoding="utf-8")
            client = vanessa.StdioMcp([sys.executable, str(fixture)], root, os.environ, root / "log", timeout=5)
            try:
                self.assertEqual(str(root), vanessa.result_text(client.tool("echo", {"path": str(root)})))
                with self.assertRaisesRegex(WorkError, "TOOL_FAILED"):
                    client.tool("fail", {"path": "ошибка"})
            finally:
                client.close()
            self.assertEqual(0, client.process.returncode)
            self.assertTrue(client.stderr.closed)

    def test_zero_steps_failed_and_missing_summary_are_rejected(self):
        for text in ("- Статус: Failed\n## Шаги (1)", "- Статус: Success\n## Шаги (0)",
                     "- Статус: Success\n## Шаги (1)\n**Failed**", "pending"):
            with self.subTest(text=text), self.assertRaises(WorkError):
                vanessa.assert_scenario_success(result(text))

    def test_feature_is_explicit_and_evidence_survives_failure_or_input_change(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            feature = root / "test.feature"
            feature.write_text("scenario", encoding="utf-8")
            calls = []
            class Client:
                def tool(self, name, args):
                    calls.append((name, args))
                    if name == "get_test_results":
                        feature.write_text("changed", encoding="utf-8")
                    return result()
            with self.assertRaisesRegex(WorkError, "FEATURE_CHANGED"):
                vanessa.run_feature(Client(), feature, root / "evidence.json")
            self.assertEqual(str(feature), calls[0][1]["filePath"])
            self.assertTrue((root / "evidence.json").is_file())

    def test_daemon_dispatches_once_preserves_identity_and_closes_owned_facade(self):
        with tempfile.TemporaryDirectory(prefix="ITL сеанс с пробелом ") as directory:
            root = Path(directory)
            control = root / "vanessa-control"
            control.mkdir()
            dependency = root / "fixture"
            dependency.touch()
            context = {"jobId": "job", "target": {"workspace": str(root),
                       "infoBase": {"kind": "file", "path": str(root / "База")},
                       "vanessa": dict.fromkeys(("facade", "helper", "catalog"), str(dependency))}}
            launch = {"jobId": "job", "pid": 123, "startedAt": "start", "instanceId": "instance",
                      "ownershipKind": "itl-broker", "infoBase": context["target"]["infoBase"]}
            write_json(root / "context.json", context)
            write_json(root / "onec-process-123.json", launch)
            calls, closed = [], []
            class Client:
                def __init__(self, *args, **kwargs): pass
                def tool(self, name, args):
                    return result("- Значение: 1") if name == "manage_variables" else result()
                def close(self): closed.append(True)
            def feature(client, path, output):
                calls.append(str(path))
                write_json(output, {"results": result()})
                if len(calls) == 3:
                    write_json(control / "request-z.json", {"jobId": "job", "operation": "cleanup"})
                return {"passed": True}
            write_json(control / "request-a.json", {"jobId": "job", "operation": "feature", "feature": "action"})
            with patch.object(vanessa, "StdioMcp", Client), patch.object(vanessa, "run_feature", feature):
                vanessa.daemon(root / "context.json", "setup")
            self.assertEqual(["setup", str(root / "vanessa-session.feature"), "action"], calls)
            self.assertEqual([True], closed)
            self.assertTrue(read_json(control / "response-a.json")["passed"])
            self.assertTrue((control / "evidence-a.json").exists())
            self.assertFalse((control / "error.json").exists())
            self.assertEqual("start", read_json(root / "session-observation.json")["clientStartedAt"])

    def test_foreign_multiple_or_unowned_launch_records_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            context = {"jobId": "job", "target": {"infoBase": {"path": "owned"}}}
            for records in ([], [{"jobId": "job", "infoBase": {"path": "foreign"}}],
                            [{"jobId": "job", "infoBase": {"path": "owned"}}]):
                for index, record in enumerate(records):
                    write_json(root / ("onec-process-%s.json" % index), record)
                with self.assertRaises(WorkError):
                    vanessa.own_launch(root, context)


if __name__ == "__main__":
    unittest.main()
