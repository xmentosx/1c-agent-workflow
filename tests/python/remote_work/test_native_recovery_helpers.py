"""Native recovery imports retained code instead of today's installed files."""
import copy
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

RUNTIME = Path(__file__).resolve().parents[3] / '.agents/skills/itl-remote-runner/scripts'
sys.path.insert(0, str(RUNTIME))
from itl_remote.access import Coordinator
from itl_remote.common import WorkError, digest
from itl_remote.native_recovery_helpers import resolve


class NativeRecoveryHelpersTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='Код восстановления с пробелом ')
        self.addCleanup(self.temp.cleanup)
        self.coordinator = Coordinator(Path(self.temp.name) / 'Общая очередь')
        names = ('agent-1c.core.ps1', 'agent-1c.runtime-values.ps1',
                 'agent-1c.sessions.ps1', 'agent-1c.vanessa.ps1')
        self.hashes = {name: hashlib.sha256(('# ' + name).encode()).hexdigest() for name in names}
        identity = '\n'.join(name + ':' + self.hashes[name] for name in names)
        self.generation = hashlib.sha256(identity.encode()).hexdigest()
        self.directory = self.coordinator.root / 'native-helper-generations' / self.generation
        self.directory.mkdir(parents=True)
        self.inputs = []
        for name in names:
            path = self.directory / name
            path.write_bytes(('# ' + name).encode())
            self.inputs.append({'path': str(path), 'sha256': digest(path)})

    def test_resolves_the_complete_retained_generation_without_original_sources(self):
        observed = resolve(self.coordinator, list(reversed(self.inputs)))
        self.assertEqual(self.generation, observed['generation'])
        self.assertEqual(self.inputs, observed['files'])

    def test_rejects_missing_or_corrupt_files_without_repairing_them(self):
        path = Path(self.inputs[0]['path'])
        original = path.read_bytes()
        for mutation in ('delete', 'corrupt'):
            with self.subTest(mutation=mutation):
                if mutation == 'delete':
                    path.unlink()
                else:
                    path.write_bytes(b'changed')
                with self.assertRaisesRegex(WorkError, 'ARCHIVE_CHANGED'):
                    resolve(self.coordinator, self.inputs)
                path.write_bytes(original)

    def test_rejects_legacy_partial_duplicate_and_cross_generation_inputs(self):
        changed = copy.deepcopy(self.inputs)
        changed[0]['path'] = str(self.directory.parent / ('0' * 64) / Path(changed[0]['path']).name)
        for inputs in (self.inputs[:3], self.inputs[:3] + self.inputs[:1], changed):
            with self.subTest(inputs=inputs), self.assertRaises(WorkError):
                resolve(self.coordinator, inputs)

    def test_does_not_import_the_same_names_from_an_unretained_installation(self):
        changed = copy.deepcopy(self.inputs)
        for item in changed:
            item['path'] = str(Path(self.temp.name) / 'current-installation' / Path(item['path']).name)
        with self.assertRaisesRegex(WorkError, 'GENERATION_REQUIRED'):
            resolve(self.coordinator, changed)

    def test_rejects_rehashed_tampering_under_the_original_generation_name(self):
        changed = copy.deepcopy(self.inputs)
        Path(changed[0]['path']).write_bytes(b'updated code')
        changed[0]['sha256'] = digest(changed[0]['path'])
        with self.assertRaisesRegex(WorkError, 'GENERATION_CHANGED'):
            resolve(self.coordinator, changed)


if __name__ == '__main__':
    unittest.main()
