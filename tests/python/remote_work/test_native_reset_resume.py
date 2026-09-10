"""Real recovery worker/pipe and file replacement; native 1C discovery is a fixture."""
import copy
from pathlib import Path
import shutil
import unittest
from unittest.mock import patch

import test_native_reset as fixtures
from itl_remote import native_reset, native_reset_resume as resume, native_journal
from itl_remote.access_recovery import Recovery, plan
from itl_remote.common import WorkError, capture, digest, read_json, write_json


WRAPPER = r'''
param($ProjectRoot,$Action,$DevBranchName)
$script:resetFixture = Get-Content -LiteralPath (Join-Path $ProjectRoot 'fixture.json') -Raw -Encoding UTF8 | ConvertFrom-Json
. $script:resetFixture.realHelper -ProjectRoot $ProjectRoot -Action help -DevBranchName $DevBranchName *> $null
function Get-MainWorktreePath { $script:ProjectRoot }
function Get-ItlDatabaseAccessSettings { $script:resetFixture.settings }
function Get-ItlOnDemandRuntimeInstances { @() }
function Get-VanessaServiceInfoBaseTemplate { $script:resetFixture.template }
function Get-SourceInfoBasePath { $script:resetFixture.source }
function Get-InfoBaseKind { 'file' }
function Get-SourceUsesRepository { $false }
function Get-BranchSeedPaths { $script:resetFixture.seedPaths }
function Invoke-Agent1cMainWorktreeReadScope { param($ScriptBlock) & $ScriptBlock }
function Stop-DevBranchRuntimeBeforeInfobaseMutation {}
function Reset-DevBranchToolingProof {}
function Initialize-DevBranchEventLogBaseline { param($State,$SeedBaselinePath) $State }
function Ensure-DevBranchEventLogPendingCursor {}
function Ensure-DevBranchEnterpriseNormalized {}
function Sync-AiRules1cManagedIgnoredFilesFromMain {}
function Invoke-DevBranchDefaultMcpSetup { param($State) $State }
function Sync-KiloItlCommandSurface {}
function Invoke-AiRules1cManagedMcpConfigReconcile {}
function Sync-DevBranchContextToDotEnv {}
function Invoke-Designer { throw 'NATIVE_1C_NOT_PART_OF_THIS_WORKER_FIXTURE' }
'''


class NativeResetResumeTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.NativeResetTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.fixture.root
        self.coordinator = self.fixture.coordinator
        self.context = self.fixture.context
        self.context['mainProject'] = str(self.root)
        self.context['archivePath'] = str(self.root / '.agent-1c/branch-archives/test/Исходный архив')
        (self.root / 'sentinel.txt').write_text('original source', encoding='utf-8')
        (self.root / '.gitignore').write_text('*\n', encoding='utf-8')
        self.git('init', '--quiet')
        self.git('config', 'user.name', 'Reset Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('add', '-f', '.gitignore', 'sentinel.txt')
        self.git('commit', '--quiet', '-m', 'original source')
        self.git('branch', '-M', 'itldev/test')
        self.git('branch', 'master', 'HEAD')
        head, tree = self.git('rev-parse', 'HEAD'), self.git('rev-parse', 'HEAD^{tree}')
        self.context.update(oldHead=head, masterCommit=head, masterTree=tree, masterConfigTree=tree)
        self.seed = Path(self.context['seed']['artifactPath'])
        self.seed.parent.mkdir(parents=True)
        self.seed.write_bytes(b'original seed database')
        baseline = Path(self.context['seed']['baselinePath'])
        baseline.write_text('{"signatures":[]}', encoding='utf-8')
        self.context['seed'].update(artifactSha256=digest(self.seed), artifactBytes=self.seed.stat().st_size,
                                    baselineSha256=digest(baseline))
        archive = Path(self.context['archivePath'])
        archive.mkdir(parents=True)
        (archive / 'infobase.dt').write_bytes(b'original database archive')
        write_json(archive / 'manifest.json', {'schemaVersion': 1, 'status': 'ready', 'oldHead': head,
            'masterCommit': head, 'dt': {'path': 'infobase.dt', 'sha256': digest(archive / 'infobase.dt'),
                                       'bytes': (archive / 'infobase.dt').stat().st_size}, 'files': []})
        self.target = Path(self.context['target']['path']) / '1Cv8.1CD'
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(b'interrupted target database')
        self.state_path = self.root / '.agent-1c/dev-branches/test.json'
        write_json(self.root / '.agent-1c/project.json', {})

    def git(self, *args):
        return capture(['git', '-C', str(self.root), *args], timeout=30).decode('utf-8').strip()

    def phase(self, phase):
        value = copy.deepcopy(self.context)
        value['phase'] = phase
        if native_reset.PHASES.index(phase) >= 1:
            path = Path(value['archivePath']) / 'manifest.json'
            value['archiveManifest'] = {'path': str(path), 'sha256': digest(path)}
        if native_reset.PHASES.index(phase) >= 2:
            value['newHead'] = value['masterCommit']
        return value

    def write_state(self, phase):
        context = self.phase(phase)
        state = {'devBranchName': 'test', 'safeDevBranchName': 'test', 'devBranch': 'itldev/test',
                 'devBranchKind': 'configuration', 'infoBaseKind': 'file', 'initializationStatus': 'ready',
                 'devBranchInfoBasePath': self.context['target']['path'], 'resetStatus': 'resetting',
                 'resetSeedIdentity': self.context['seed'], 'resetPhase': phase, 'resetNewHead': context['newHead']}
        for field, source in {'resetOldHead': 'oldHead', 'resetMasterCommit': 'masterCommit', 'resetMasterTree': 'masterTree',
                'resetMasterConfigTreeObjectId': 'masterConfigTree', 'resetMasterFingerprint': 'masterFingerprint',
                'resetArchivePath': 'archivePath'}.items():
            state[field] = self.context[source]
        state['resetArchiveDtPath'] = str(Path(self.context['archivePath']) / 'infobase.dt')
        write_json(self.state_path, state)

    def worker_package(self):
        actual = Path(resume.__file__).resolve().parent.parent
        skills = self.root / 'Пакет восстановления/.agents/skills'
        runtime = skills / 'itl-remote-runner/scripts'
        helper = skills / '1c-workflow/scripts/agent-1c.ps1'
        runtime.mkdir(parents=True)
        (helper.parent / 'lib').mkdir(parents=True)
        shutil.copyfile(actual / 'Resume-NativeReset.ps1', runtime / 'Resume-NativeReset.ps1')
        helper.write_text(WRAPPER, encoding='utf-8-sig')
        (helper.parent / 'lib/fixture.ps1').write_text('# fixture package inventory', encoding='utf-8')
        seed_paths = {'root': str(self.seed.parent), 'sourceKey': self.context['seed']['sourceKey'],
                      'artifactKind': 'file-1cd', 'artifactPath': str(self.seed)}
        for key, name in {'manifestPath': 'manifest.json', 'baselinePath': 'baseline.json',
                          'leasePath': 'seed.lease', 'writerIntentPath': 'seed.writer.lock',
                          'rebuildMarkerPath': 'rebuild.marker.json'}.items():
            seed_paths[key] = str(self.seed.parent / name)
        write_json(Path(seed_paths['manifestPath']), {**self.context['seed'], 'status': 'ready',
                   'baselineCount': 0, 'baselineErrorCount': 0, 'baselineReader': 'fixture'})
        template = self.root / 'Шаблон службы.dt'
        template.write_bytes(b'fixture service template; not a native DT')
        import sys
        write_json(self.root / 'fixture.json', {'realHelper': str(actual.parent.parent / '1c-workflow/scripts/agent-1c.ps1'),
            'settings': {'coordinator': str(self.coordinator.root), 'python': sys.executable, 'waitTimeoutSeconds': 0},
            'template': {'path': str(template), 'sha256': digest(template), 'user': 'Runner', 'password': ''},
            'source': str(self.root / 'Исходная база'), 'seedPaths': seed_paths})
        return str(runtime / 'itl_remote/native_reset_resume.py')

    def observations(self, recovery, journal):
        resources = []
        for base in self.fixture.fixture.plan['bases']:
            present = base == self.context['target']
            resources.append({**base, 'databasePresent': present, 'directoryPresent': present,
                              'exclusive': present, 'sessionCount': 0})
        return [{'observation': {'samples': [{'resources': resources}, {'resources': resources}]}}]

    def run_worker(self, failure=False):
        self.write_state('runtime-initializing')  # persisted one phase before ACK
        package = self.worker_package()
        if failure:
            helper = Path(package).parent.parent.parent.parent / '1c-workflow/scripts/agent-1c.ps1'
            helper.write_text(helper.read_text(encoding='utf-8-sig').replace(
                'function Ensure-DevBranchEnterpriseNormalized {}',
                "function Ensure-DevBranchEnterpriseNormalized { throw 'EXTERNAL_PROCESSOR_SECURITY_PROMPT' }"), encoding='utf-8-sig')
        original_archive = digest(Path(self.context['archivePath']) / 'infobase.dt')
        with self.fixture.fixture.lease() as original:
            producer = self.fixture.start(original)['producerId']
            for phase in native_reset.PHASES[:3]:
                native_reset.publish(original, producer, self.phase(phase))
            original.release(cleanup_errors=native_journal.release_errors(original, producer))
        prepared = plan(self.coordinator.root, original.record['ticket'])
        with Recovery(self.coordinator.root, original.record['ticket'], prepared['revision'], {'operation': 'worker-fixture'}) as recovery:
            journal = native_journal.inspect(self.coordinator, recovery._current(), resolve_helpers=True)
            with patch.object(resume, '__file__', package), patch(
                    'itl_remote.native_recovery.inspect_native_work', side_effect=self.observations):
                try:
                    if failure:
                        with self.assertRaisesRegex(WorkError, 'NATIVE_RESET_RECOVERY_WORKER_FAILED: stage=.*EXTERNAL_PROCESSOR_SECURITY_PROMPT.*log=.*status=.*admission retained'):
                            recovery.complete(lambda _: resume.recover(recovery, journal, []))
                    else:
                        receipt = recovery.complete(lambda _: resume.recover(recovery, journal, []))
                except Exception:
                    logs = list((self.coordinator.root / 'recovery-observations').rglob('*.log'))
                    for log in logs:
                        print(log.read_text(encoding='utf-8', errors='replace')[-12000:])
                    raise
        if failure:
            record = read_json(self.coordinator.root / 'tickets' / (original.record['ticket'] + '.json'))
            self.assertEqual('needs-attention', record['status'])
            self.assertEqual('runtime-initializing', read_json(self.state_path)['resetPhase'])
            with self.assertRaisesRegex(WorkError, 'RECOVERY_REQUIRED'):
                with self.fixture.fixture.lease(): pass
        else:
            self.assertEqual('released', receipt['status'])
            self.assertEqual('complete', read_json(self.state_path)['resetPhase'])
            with self.fixture.fixture.lease(): pass
        self.assertEqual(self.seed.read_bytes(), self.target.read_bytes())
        self.assertEqual(original_archive, digest(Path(self.context['archivePath']) / 'infobase.dt'))
        self.assertEqual(self.context['masterCommit'], self.git('rev-parse', 'HEAD'))

    def test_worker_resumes_file_replacement_with_original_inputs_and_releases_after_completion(self):
        self.run_worker()

    def test_worker_failure_reports_the_original_cause_and_retains_the_database(self):
        self.run_worker(failure=True)

    def test_checkout_preflight_preserves_user_changes_and_rejects_branch_switch(self):
        context = self.phase('git-reset-complete')
        resume._checkout(context)
        (self.root / 'sentinel.txt').write_text('user changes after interruption', encoding='utf-8')
        with self.assertRaisesRegex(WorkError, 'USER_CHANGES_PRESENT'):
            resume._checkout(context)
        self.git('add', 'sentinel.txt')
        self.git('commit', '--quiet', '-m', 'user change')
        with self.assertRaisesRegex(WorkError, 'HEAD_CHANGED'):
            resume._checkout(context)
        with self.assertRaisesRegex(WorkError, 'TREE_CHANGED'):
            resume._checkout({**context, 'newHead': self.git('rev-parse', 'HEAD')})
        self.git('switch', '--quiet', '-c', 'itldev/other')
        with self.assertRaisesRegex(WorkError, 'CHECKOUT_CHANGED'):
            resume._checkout(context)


if __name__ == '__main__':
    unittest.main()
