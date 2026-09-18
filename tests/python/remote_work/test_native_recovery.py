"""Fresh-process reconciliation of preparation; no simulated native success."""
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

RUNTIME = Path(__file__).resolve().parents[3] / '.agents/skills/itl-remote-runner/scripts'
sys.path.insert(0, str(RUNTIME))
from itl_remote.access import Coordinator, Lease
from itl_remote.access_autorecovery import enter_root_lease
from itl_remote.common import WorkError, read_json, write_json
from itl_remote.native_recovery import (VERIFICATION_OPERATIONS, WORKFLOW_OPERATIONS,
                                        _stable_owned_processes, recover_workflow_operation)

CHILD = r'''
import hashlib, os, sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1]); sys.path.insert(0, sys.argv[2])
from test_restoration_journal import RestorationJournalTests
from itl_remote.access import Coordinator, Lease
from itl_remote.common import digest, read_json, write_json
from itl_remote import native_journal as native, native_continuation as continuation, restoration_journal as duties
from itl_remote.native_recovery_helpers import NAMES
c = read_json(sys.argv[3]); root = Path(c['root']); kind = c['case']
project = Path(c.get('project', str(root)))
fixture = RestorationJournalTests()
fixture.root = root; fixture.coordinator = Coordinator(root / 'Общая очередь')
fixture.base = {'kind': 'file', 'path': str(root / 'База проекта')}
server_case = kind == 'server-repository-capture'
if server_case: fixture.base = {'kind': 'server', 'path': 'server:1541/База проекта'}
operation = 'unknown-operation' if kind == 'unknown-operation' else ('lock-config-repository-objects' if kind in ('repository-capture', 'server-repository-capture') else 'export-dev-branch-result')
read_only = kind.startswith('read-only:')
if read_only: operation = kind.split(':')[1]
verification_operation = ('check-dev-branch' if kind == 'verification-check' else
                          kind.split(':', 1)[1] if kind.startswith('verification:') else '')
verification_check = bool(verification_operation)
if verification_check: operation = verification_operation
tooling_repair = kind == 'tooling-repair'
if tooling_repair: operation = 'repair-dev-branch-tooling'
refresh_retry = kind in ('refresh-retry', 'refresh-missing-seed', 'refresh-missing-seed-legacy', 'refresh-required-missing')
if refresh_retry: operation = 'refresh-dev-branch'
sync_master_retry = kind in ('sync-master-retry', 'sync-master-missing-seed')
if sync_master_retry: operation = 'sync-master'
completion = kind.startswith('committed')
bases = [fixture.base]
service = None
if verification_check or tooling_repair or refresh_retry:
    service = {'kind': 'file', 'path': str(project / '.agent-1c/infobases' / ('vanessa-service-' + 'a' * 32))}
    bases.append(service)
seed = None
if kind in ('refresh-missing-seed', 'refresh-missing-seed-legacy', 'sync-master-missing-seed'):
    seed = {'kind': 'file', 'path': c['seedPath']}
    Path(seed['path']).mkdir(parents=True, exist_ok=True)
    bases.append(seed)
if kind == 'refresh-required-missing':
    bases.append({'kind': 'file', 'path': str(root / 'Обязательная отсутствующая база')})
if completion:
    operation = 'init-dev-branch-extension'
    if kind in ('committed-unused-service', 'committed-damaged-service'):
        bases.append({'kind': 'file', 'path': str(root / '.agent-1c/infobases' / ('vanessa-service-' + 'a' * 32))})
        if kind == 'committed-damaged-service': Path(bases[-1]['path']).mkdir(parents=True)
    elif kind == 'committed-other-database':
        bases.append({'kind': 'file', 'path': str(root / 'Другая рабочая база')})
with Lease(fixture.coordinator.root, bases, {'nativeJournalProtocol': 1, 'parentPid': os.getpid(),
        'operation': operation, 'project': str(project)}, timeout=0) as lease:
    producer = native.register(lease)
    value = fixture.database_payload(lease, policy='on-failure') if completion else fixture.payload(lease, existed=kind != 'absent')
    value['project'] = str(project)
    if not completion and project != root:
        destination = project / 'Исходники с пробелом' / 'ConfigDumpInfo.xml'
        destination.parent.mkdir(parents=True, exist_ok=True)
        value['destination'] = str(destination)
    if completion: value.update(operation=operation, resources=bases)
    contents = {name: ('# retained ' + name).encode() for name in NAMES}
    if completion or read_only or verification_check or tooling_repair or refresh_retry or sync_master_retry or kind in ('native-started', 'repository-capture', 'server-repository-capture'):
        library = Path(sys.argv[1]).parent.parent / '1c-workflow/scripts/lib'
        contents = {name: (library / name).read_bytes() for name in NAMES}
    hashes = {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()}
    generation = hashlib.sha256('\n'.join(name + ':' + hashes[name] for name in NAMES).encode()).hexdigest()
    directory = fixture.coordinator.root / 'native-helper-generations' / generation
    directory.mkdir(parents=True)
    for name, data in contents.items(): (directory / name).write_bytes(data)
    value['helperInputs'] = [{'path': str(directory / name), 'sha256': hashes[name]} for name in NAMES]
    duties.publish(lease, producer, value)
    if verification_check or tooling_repair or refresh_retry or sync_master_retry:
        plan = {'schemaVersion': 1, 'operation': operation, 'project': str(project),
                'target': fixture.base, 'bases': bases, 'helperInputs': value['helperInputs'],
                'serviceGeneration': 'a' * 32 if service else '', 'serviceReserveGeneration': ''}
        if seed is not None and kind != 'refresh-missing-seed-legacy':
            plan['schemaVersion'] = 2
            plan['resourceRoles'] = ([{**service, 'role': 'vanessa-service'}] if service else []) + [
                {**seed, 'role': 'branch-seed'}]
        continuation.publish(lease, producer, plan)
    if kind == 'nested':
        inner = fixture.payload(lease)
        inner['createdAt'] = '2026-09-10T00:00:01Z'
        Path(inner['snapshotPath']).write_bytes(b'intermediate cursor')
        inner['snapshotSha256'] = digest(inner['snapshotPath'])
        inner['helperInputs'] = value['helperInputs']
        duties.publish(lease, producer, inner)
    if not completion: Path(value['destination']).write_bytes(b'interrupted preparation cursor')
    if completion or read_only or verification_check or tooling_repair or refresh_retry or sync_master_retry or kind in ('native-started', 'repository-capture', 'server-repository-capture'):
        operation_record = fixture.native_restore(value)
        operation_record['helperInputs'] = value['helperInputs']
        if completion or read_only or verification_check or tooling_repair or refresh_retry or sync_master_retry or kind in ('repository-capture', 'server-repository-capture'):
            operation_record['purpose'] = 'designer-designer-command'
            if fixture.base['kind'] == 'file':
                Path(fixture.base['path']).mkdir()
                (Path(fixture.base['path']) / '1Cv8.1CD').write_bytes(b'fixture database-file access sentinel; not a 1C database')
            write_json(root / 'repository-claims.json', {'objects': ['Configuration'], 'owner': 'original-owner'})
        if server_case:
            provider = root / 'server recovery provider.ps1'
            provider.write_text(r"""param([string]$Operation,[string]$ProjectRoot,[string]$InfoBasePath,[string]$ObservationId,[int]$Sample)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $OutputEncoding
if ($Operation -ne 'recovery-observe') { exit 8 }
[pscustomobject]@{schemaVersion=1;observationId=$ObservationId;infoBase=@{kind='server';path=$InfoBasePath};databasePresent=$true;sessionCount=0;exclusive=$true} | ConvertTo-Json -Compress
""", encoding='utf-8-sig')
            operation_record['effectContract'] = None
            operation_record['outcome'] = {'status': 'pending', 'recordedAt': ''}
            operation_record['serverRecoveryInspector'] = {'schemaVersion': 1, 'path': str(provider),
                'sha256': digest(provider), 'capability': 'recovery-observe'}
        if read_only:
            operation_record['purpose'] = 'designer-designer-command' if kind.endswith(':write') else 'designer-dump-config-to-files'
        if verification_check or refresh_retry or sync_master_retry:
            operation_record['operation'] = operation
            operation_record['purpose'] = 'enterprise-run'
        if tooling_repair:
            operation_record['operation'] = operation
            operation_record['purpose'] = 'enterprise-run'
            Path(service['path']).mkdir(parents=True)
            (Path(service['path']) / '1Cv8.1CD').write_bytes(b'fixture service database-file access sentinel')
        native.publish(lease, producer, operation_record)
    if completion:
        (root / 'saved-source.bsl').write_bytes(b'\xef\xbb\xbfcommitted source\r\n')
        (root / '.dev.env').write_bytes(b'COMMITTED_ENV=value\r\n')
        write_json(root / 'saved-state.json', {'lastVerificationStatus': 'stale', 'extensionInitializationStatus': 'ready'})
        value.update(status='committed', updatedAt='2026-09-10T00:00:02Z')
        duties.publish(lease, producer, value)
        Path(value['snapshotPath']).unlink()  # Ordinary completion already cleaned the DT.
        if kind == 'committed-later-work':
            import uuid
            operation_record.update(id=uuid.uuid4().hex, createdAt='2026-09-10T00:00:03Z', updatedAt='2026-09-10T00:00:04Z')
            native.publish(lease, producer, operation_record)
        if kind == 'committed-pending-cursor':
            cursor = fixture.payload(lease)
            cursor['helperInputs'] = value['helperInputs']
            duties.publish(lease, producer, cursor)
    if kind == 'live-producer':
        lease.release(cleanup_errors=['fixture host exited before producer'])
    write_json(root / 'ready.json', {'ticket': lease.record['ticket'], 'value': value, 'base': fixture.base,
                                     'bases': bases, 'seed': seed, 'project': str(project)})
    if kind == 'live-producer':
        while True: time.sleep(.1)
    os._exit(19)
'''


class NativeRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='Перезапуск восстановления ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.coordinator = Coordinator(self.root / 'Общая очередь')

    def test_operation_set_matches_the_public_admission_route(self):
        entry = RUNTIME.parent.parent / '1c-workflow/scripts/agent-1c.ps1'
        source = entry.read_text(encoding='utf-8-sig')
        match = re.search(r"if \(\$requestedLifecycleAction -in @\(([^\r\n]+)\)\)", source)
        self.assertIsNotNone(match)
        self.assertEqual(WORKFLOW_OPERATIONS, frozenset(re.findall(r"'([^']+)'", match.group(1))))
        self.assertEqual(frozenset({
            'check-dev-branch', 'verify-dev-branch', 'check-auxiliary-contour', 'deploy-and-test',
        }), VERIFICATION_OPERATIONS)
        self.assertTrue(VERIFICATION_OPERATIONS <= WORKFLOW_OPERATIONS)

    def test_owned_process_identity_must_be_stable_across_recovery_samples(self):
        process = {'pid': 40112, 'processStartTime': '2026-09-18T14:07:40+00:00',
                   'name': '1cv8c.exe', 'executablePath': str(self.root / '1cv8c.exe')}
        observation = {'observation': {'samples': [
            {'resources': [{'ownedProcesses': [dict(process)]}]},
            {'resources': [{'ownedProcesses': [dict(process)]}]},
        ]}}
        self.assertEqual([process], _stable_owned_processes(observation))
        observation['observation']['samples'][1]['resources'][0]['ownedProcesses'] = []
        self.assertEqual([], _stable_owned_processes(observation))
        observation['observation']['samples'][1]['resources'][0]['ownedProcesses'] = [dict(process)]
        observation['observation']['samples'][1]['resources'][0]['ownedProcesses'][0]['processStartTime'] = '2026-09-18T14:08:40+00:00'
        with self.assertRaisesRegex(WorkError, 'OWNED_PROCESS_SET_UNSTABLE'):
            _stable_owned_processes(observation)

    def orphan(self, case='normal', *, project=None, seed_path=None):
        path = self.root / 'request.json'
        request = {'root': str(self.root), 'case': case}
        if project is not None:
            request['project'] = str(project)
        if seed_path is not None:
            request['seedPath'] = str(seed_path)
        write_json(path, request)
        process = subprocess.Popen([sys.executable, '-B', '-X', 'utf8', '-c', CHILD,
                                    str(RUNTIME), str(Path(__file__).parent), str(path)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        def cleanup():
            if process.poll() is None: process.kill()
            process.wait(timeout=10)
            process.stderr.close()
        self.addCleanup(cleanup)
        deadline = time.monotonic() + 10
        while not (self.root / 'ready.json').exists():
            if process.poll() is not None or time.monotonic() > deadline:
                if process.poll() is None: process.kill()
                self.fail('Producer did not prepare the fixture: ' + process.stderr.read().decode('utf-8', errors='replace'))
            time.sleep(.02)
        if case != 'live-producer':
            self.assertEqual(19, process.wait(timeout=10))
        return read_json(self.root / 'ready.json')

    def linked_worktrees(self):
        main = self.root / 'Git main с пробелом'
        branch = self.root / 'Git branch с пробелом'
        main.mkdir()
        def git(*arguments):
            result = subprocess.run(['git', '-c', 'core.quotepath=false', '-C', str(main), *arguments],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(0, result.returncode, result.stderr.decode('utf-8', errors='replace'))
        git('init')
        git('config', 'user.email', 'fixture@example.com')
        git('config', 'user.name', 'Recovery Fixture')
        (main / 'tracked.txt').write_text('fixture', encoding='utf-8')
        git('add', 'tracked.txt')
        git('commit', '-m', 'fixture')
        git('worktree', 'add', '-b', 'itldev/recovery-fixture', str(branch), 'HEAD')
        return main, branch

    def test_fresh_cli_restores_cursor_and_releases_only_after_producer_exit(self):
        data = self.orphan()
        before = read_json(self.coordinator.root / 'tickets' / (data['ticket'] + '.json'))
        result = subprocess.run([sys.executable, '-B', '-X', 'utf8', str(RUNTIME / 'remote_work.py'), 'access-recover-workflow',
                                 '--coordinator', str(self.coordinator.root), '--ticket', data['ticket']],
                                cwd=RUNTIME, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        self.assertEqual(0, result.returncode, result.stderr.decode())
        record = json.loads(result.stdout)
        self.assertEqual('released', record['status'])
        self.assertEqual(before['nativeJournal'], record['nativeJournal'])
        self.assertEqual('interrupted', record['recoveryAttempts'][-1]['evidence']['originalOutcome'])
        self.assertEqual(Path(data['value']['snapshotPath']).read_bytes(), Path(data['value']['destination']).read_bytes())
        with Lease(self.coordinator.root, [data['base']], {'operation': 'next-chat'}, timeout=0):
            pass

    def test_nested_cursor_recovery_restores_the_outer_original(self):
        data = self.orphan('nested')
        record = recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertEqual('released', record['status'])
        self.assertEqual(Path(data['value']['snapshotPath']).read_bytes(), Path(data['value']['destination']).read_bytes())
        self.assertEqual(1, len(record['recoveryAttempts'][-1]['evidence']['restorations']))

    def test_original_absence_is_restored(self):
        data = self.orphan('absent')
        recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertFalse(Path(data['value']['destination']).exists())

    def test_live_producer_cannot_be_recovered_after_its_lease_host_exits(self):
        data = self.orphan('live-producer')
        with self.assertRaisesRegex(WorkError, 'PRODUCER_STILL_RUNNING'):
            recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertEqual(b'interrupted preparation cursor', Path(data['value']['destination']).read_bytes())

    def test_started_native_work_requires_its_adapter_even_with_saved_quiescence(self):
        data = self.orphan('native-started')
        with self.assertRaisesRegex(WorkError, 'STARTED_OPERATION_ADAPTER_REQUIRED'):
            try:
                recover_workflow_operation(self.coordinator.root, data['ticket'])
            except WorkError as error:
                if 'COMMAND_FAILED' in str(error):
                    logs = list((self.coordinator.root / 'recovery-observations').rglob('*.observation.json'))
                    self.fail('\n'.join(log.read_text(encoding='utf-8-sig') for log in logs))
                raise
        self.assertEqual(b'interrupted preparation cursor', Path(data['value']['destination']).read_bytes())
        record = read_json(self.coordinator.root / 'tickets' / (data['ticket'] + '.json'))
        evidence = record['recoveryAttempts'][-1]['nativeObservations']
        self.assertEqual(1, len(evidence))
        self.assertEqual(2, len(evidence[0]['observation']['samples']))
        for sample in evidence[0]['observation']['samples']:
            self.assertEqual(0, sample['resources'][0]['sessionCount'])
        with self.assertRaisesRegex(WorkError, 'RECOVERY_REQUIRED'):
            with Lease(self.coordinator.root, [data['base']], {}, timeout=0): pass

    @unittest.skipUnless(os.name == 'nt', 'native database observation uses Windows PowerShell')
    def test_interrupted_refresh_releases_only_for_canonical_retry(self):
        data = self.orphan('refresh-retry')
        record = recover_workflow_operation(self.coordinator.root, data['ticket'])
        evidence = record['recoveryAttempts'][-1]['evidence']
        self.assertEqual('released', record['status'])
        self.assertEqual('workflow-refresh-retry', evidence['adapter'])
        self.assertIn('rerun the same canonical refresh command', evidence['resultAcceptance'])
        self.assertEqual(Path(data['value']['snapshotPath']).read_bytes(), Path(data['value']['destination']).read_bytes())

    @unittest.skipUnless(os.name == 'nt', 'native database observation uses Windows PowerShell')
    def test_interrupted_sync_master_releases_only_for_canonical_retry(self):
        data = self.orphan('sync-master-retry')
        record = recover_workflow_operation(self.coordinator.root, data['ticket'])
        evidence = record['recoveryAttempts'][-1]['evidence']
        self.assertEqual('released', record['status'])
        self.assertEqual('workflow-sync-master-retry', evidence['adapter'])
        self.assertIn('rerun the canonical sync-master command', evidence['resultAcceptance'])

    @unittest.skipUnless(os.name == 'nt', 'native database observation uses Windows PowerShell')
    def test_interrupted_sync_master_releases_with_partial_explicit_seed_role(self):
        seed = self.root / '.agent-1c/branch-seed' / ('b' * 64) / 'infobase'
        data = self.orphan('sync-master-missing-seed', seed_path=seed)
        record = recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertEqual('released', record['status'])
        evidence = record['recoveryAttempts'][-1]['evidence']
        self.assertEqual('workflow-sync-master-retry', evidence['adapter'])
        for sample in evidence['nativeObservations'][0]['observation']['samples']:
            observed = next(base for base in sample['resources'] if base['path'] == str(seed))
            self.assertFalse(observed['databasePresent'])
            self.assertTrue(observed['directoryPresent'])

    @unittest.skipUnless(os.name == 'nt', 'native database observation uses Windows PowerShell')
    def test_required_missing_database_is_not_misreported_as_busy(self):
        data = self.orphan('refresh-required-missing')
        with self.assertRaisesRegex(WorkError, 'NATIVE_RECOVERY_REQUIRED_DATABASE_MISSING'):
            recover_workflow_operation(self.coordinator.root, data['ticket'])
        with self.assertRaisesRegex(WorkError, 'RECOVERY_REQUIRED'):
            with Lease(self.coordinator.root, data['bases'], {'operation': 'next-chat'}, timeout=0):
                pass

    @unittest.skipUnless(os.name == 'nt', 'native database observation uses Windows PowerShell')
    def test_legacy_refresh_orphan_with_missing_seed_recovers_from_linked_master_worktree(self):
        main, branch = self.linked_worktrees()
        seed = main / '.agent-1c' / 'branch-seed' / ('b' * 64) / 'infobase'
        data = self.orphan('refresh-missing-seed-legacy', project=branch, seed_path=seed)
        lease = enter_root_lease(self.coordinator.root, [data['seed']],
                                 {'project': str(main), 'operation': 'sync-master'},
                                 timeout=0, access_mode='mutation-exclusive')
        try:
            self.assertNotEqual(data['ticket'], lease.record['ticket'])
            old = self.coordinator.record(data['ticket'])
            self.assertEqual('released', old['status'])
            self.assertEqual('workflow-refresh-retry', old['recoveryAttempts'][-1]['evidence']['adapter'])
        finally:
            lease.release()

    @unittest.skipUnless(os.name == 'nt', 'native database observation uses Windows PowerShell')
    def test_failed_verification_releases_only_after_live_inspection_and_cursor_restore(self):
        data = self.orphan('verification-check')
        record = recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertEqual('released', record['status'])
        evidence = record['recoveryAttempts'][-1]['evidence']
        self.assertEqual('workflow-verification-check', evidence['adapter'])
        self.assertEqual('interrupted', evidence['originalOutcome'])
        self.assertIn('no passing result is accepted', evidence['resultAcceptance'])
        self.assertEqual(Path(data['value']['snapshotPath']).read_bytes(), Path(data['value']['destination']).read_bytes())
        for sample in evidence['nativeObservations'][0]['observation']['samples']:
            resources = {Path(value['path']).name: value for value in sample['resources']}
            self.assertEqual(0, resources['База проекта']['sessionCount'])
            self.assertTrue(resources['База проекта']['exclusive'])
            service = resources['vanessa-service-' + 'a' * 32]
            self.assertFalse(service['databasePresent'])
            self.assertFalse(service['directoryPresent'])
            self.assertEqual(0, service['sessionCount'])
        planned = [data['base'], {'kind': 'file', 'path': str(
            self.root / '.agent-1c/infobases' / ('vanessa-service-' + 'a' * 32))}]
        with Lease(self.coordinator.root, planned, {'operation': 'next-chat'}, timeout=0):
            pass

    @unittest.skipUnless(os.name == 'nt', 'native database observation uses Windows PowerShell')
    def test_verify_dev_branch_uses_the_same_verification_recovery_contract(self):
        data = self.orphan('verification:verify-dev-branch')
        record = recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertEqual('released', record['status'])
        self.assertEqual('workflow-verification-check', record['recoveryAttempts'][-1]['evidence']['adapter'])

    @unittest.skipUnless(os.name == 'nt', 'native database observation uses Windows PowerShell')
    def test_auxiliary_check_uses_the_same_verification_recovery_contract(self):
        data = self.orphan('verification:check-auxiliary-contour')
        record = recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertEqual('released', record['status'])
        self.assertEqual('workflow-verification-check', record['recoveryAttempts'][-1]['evidence']['adapter'])

    @unittest.skipUnless(os.name == 'nt', 'native database observation uses Windows PowerShell')
    def test_failed_verification_releases_a_partially_created_planned_service_generation(self):
        data = self.orphan('verification-check')
        service = self.root / '.agent-1c/infobases' / ('vanessa-service-' + 'a' * 32)
        service.mkdir(parents=True)
        record = recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertEqual('released', record['status'])
        with Lease(self.coordinator.root, [data['base'], {'kind': 'file', 'path': str(service)}], {}, timeout=0):
            pass

    @unittest.skipUnless(os.name == 'nt', 'native database observation uses Windows PowerShell')
    def test_failed_tooling_repair_releases_only_after_live_inspection(self):
        data = self.orphan('tooling-repair')
        record = recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertEqual('released', record['status'])
        evidence = record['recoveryAttempts'][-1]['evidence']
        self.assertEqual('workflow-tooling-repair', evidence['adapter'])
        self.assertIn('does not create a readiness result', evidence['resultAcceptance'])
        for sample in evidence['nativeObservations'][0]['observation']['samples']:
            self.assertTrue(all(value['exclusive'] and value['sessionCount'] == 0
                                for value in sample['resources']))
        service = {'kind': 'file', 'path': str(
            self.root / '.agent-1c/infobases' / ('vanessa-service-' + 'a' * 32))}
        with Lease(self.coordinator.root, [data['base'], service], {'operation': 'next-chat'}, timeout=0):
            pass

    def test_corrupt_snapshot_does_not_overwrite_the_current_file(self):
        data = self.orphan()
        Path(data['value']['snapshotPath']).write_bytes(b'corrupt')
        with self.assertRaisesRegex(WorkError, 'SNAPSHOT_CHANGED'):
            recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertEqual(b'interrupted preparation cursor', Path(data['value']['destination']).read_bytes())

    def test_repository_capture_retains_claims_and_releases_only_after_live_inspection(self):
        data = self.orphan('repository-capture')
        claims = (self.root / 'repository-claims.json').read_bytes()
        original = read_json(self.coordinator.root / 'tickets' / (data['ticket'] + '.json'))['nativeJournal']
        record = recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertEqual('released', record['status'])
        self.assertEqual(claims, (self.root / 'repository-claims.json').read_bytes())
        self.assertEqual(original, record['nativeJournal'])
        evidence = record['recoveryAttempts'][-1]['evidence']
        self.assertEqual('workflow-repository-capture', evidence['adapter'])
        self.assertEqual('interrupted', evidence['originalOutcome'])
        self.assertTrue(evidence['nativeStartAttempted'])

    @unittest.skipUnless(os.name == 'nt', 'native server observation uses Windows PowerShell')
    def test_server_repository_capture_releases_only_after_two_provider_observations(self):
        data = self.orphan('server-repository-capture')
        record = recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertEqual('released', record['status'])
        evidence = record['recoveryAttempts'][-1]['evidence']
        self.assertEqual('workflow-repository-capture', evidence['adapter'])
        self.assertEqual(1, len(evidence['nativeObservations']))
        for sample in evidence['nativeObservations'][0]['observation']['samples']:
            self.assertEqual('server', sample['resources'][0]['kind'])
            self.assertEqual(0, sample['resources'][0]['sessionCount'])
            self.assertTrue(sample['resources'][0]['exclusive'])

    def test_repository_capture_waits_for_an_independent_file_handle(self):
        data = self.orphan('repository-capture')
        with (Path(data['base']['path']) / '1Cv8.1CD').open('rb'):
            with self.assertRaisesRegex(WorkError, 'DATABASE_STILL_IN_USE'):
                recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertEqual(b'interrupted preparation cursor', Path(data['value']['destination']).read_bytes())
        with self.assertRaisesRegex(WorkError, 'RECOVERY_REQUIRED'):
            with Lease(self.coordinator.root, [data['base']], {}, timeout=0): pass

    def test_unknown_operation_does_not_gain_an_invented_restoration_contract(self):
        data = self.orphan('unknown-operation')
        with self.assertRaisesRegex(WorkError, 'OPERATION_CONTRACT_REQUIRED'):
            recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertEqual(b'interrupted preparation cursor', Path(data['value']['destination']).read_bytes())

    def assert_dump_recovery(self, operation):
        data = self.orphan('read-only:' + operation)
        artifact = self.root / 'partial-dump.xml'
        artifact.write_bytes(b'incomplete dump must remain unaccepted')
        database = Path(data['base']['path']) / '1Cv8.1CD'
        original_database = database.read_bytes()
        result = subprocess.run([sys.executable, '-B', '-X', 'utf8', str(RUNTIME / 'remote_work.py'),
                                 'access-recover-workflow', '--coordinator', str(self.coordinator.root),
                                 '--ticket', data['ticket']], cwd=RUNTIME, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(0, result.returncode, result.stderr.decode())
        record = json.loads(result.stdout)
        self.assertEqual('released', record['status'])
        evidence = record['recoveryAttempts'][-1]['evidence']
        self.assertEqual('workflow-read-only-dump', evidence['adapter'])
        self.assertEqual('interrupted', evidence['originalOutcome'])
        self.assertIn('not accepted', evidence['resultAcceptance'])
        self.assertEqual(original_database, database.read_bytes())
        self.assertEqual(b'incomplete dump must remain unaccepted', artifact.read_bytes())
        self.assertEqual(Path(data['value']['snapshotPath']).read_bytes(), Path(data['value']['destination']).read_bytes())
        with Lease(self.coordinator.root, [data['base']], {'operation': 'next-chat'}, timeout=0): pass

    def test_full_source_dump_releases_through_public_recovery_without_accepting_partial_files(self):
        self.assert_dump_recovery('loadfrom1cbase')

    def test_selected_source_dump_releases_through_public_recovery(self):
        self.assert_dump_recovery('getconfigfiles')

    def test_extension_source_dump_releases_through_public_recovery(self):
        self.assert_dump_recovery('dump-dev-branch-extension')

    def test_read_only_dump_does_not_release_a_database_with_an_independent_handle(self):
        data = self.orphan('read-only:loadfrom1cbase')
        with (Path(data['base']['path']) / '1Cv8.1CD').open('rb'):
            with self.assertRaisesRegex(WorkError, 'DATABASE_STILL_IN_USE'):
                recover_workflow_operation(self.coordinator.root, data['ticket'])
        with self.assertRaisesRegex(WorkError, 'RECOVERY_REQUIRED'):
            with Lease(self.coordinator.root, [data['base']], {}, timeout=0): pass
        record = recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertEqual('released', record['status'])

    def test_dump_operation_name_does_not_authorize_recovery_of_a_native_write(self):
        data = self.orphan('read-only:loadfrom1cbase:write')
        with self.assertRaisesRegex(WorkError, 'STARTED_OPERATION_ADAPTER_REQUIRED'):
            recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertEqual(b'interrupted preparation cursor', Path(data['value']['destination']).read_bytes())
        with self.assertRaisesRegex(WorkError, 'RECOVERY_REQUIRED'):
            with Lease(self.coordinator.root, [data['base']], {}, timeout=0): pass

    def test_committed_result_survives_recovery_after_snapshot_cleanup(self):
        data = self.orphan('committed-unused-service')
        files = [self.root / name for name in ('saved-source.bsl', '.dev.env', 'saved-state.json')]
        before = {path: path.read_bytes() for path in files}
        journal = read_json(self.coordinator.root / 'tickets' / (data['ticket'] + '.json'))['nativeJournal']
        self.assertFalse(Path(data['value']['snapshotPath']).exists())
        record = recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertEqual('released', record['status'])
        self.assertEqual(journal, record['nativeJournal'])
        self.assertEqual(before, {path: path.read_bytes() for path in files})
        evidence = record['recoveryAttempts'][-1]['evidence']
        self.assertEqual('commit-acknowledged-before-interruption', evidence['resolution'])
        self.assertEqual('interrupted', evidence['originalOutcome'])
        with Lease(self.coordinator.root, data['value']['resources'], {'operation': 'next-chat'}, timeout=0): pass

    def test_committed_result_does_not_release_after_later_native_work(self):
        data = self.orphan('committed-later-work')
        with self.assertRaisesRegex(WorkError, 'WORK_AFTER_COMPLETION'):
            recover_workflow_operation(self.coordinator.root, data['ticket'])

    def test_committed_result_does_not_discard_pending_cursor_duties(self):
        data = self.orphan('committed-pending-cursor')
        with self.assertRaisesRegex(WorkError, 'COMPLETION_CONTRACT_REQUIRED'):
            recover_workflow_operation(self.coordinator.root, data['ticket'])

    def test_committed_result_does_not_cover_another_business_database(self):
        data = self.orphan('committed-other-database')
        with self.assertRaisesRegex(WorkError, 'ADDITIONAL_DATABASE_COMPLETION_REQUIRED'):
            recover_workflow_operation(self.coordinator.root, data['ticket'])

    def test_committed_result_releases_a_partially_created_unused_service(self):
        data = self.orphan('committed-damaged-service')
        record = recover_workflow_operation(self.coordinator.root, data['ticket'])
        self.assertEqual('released', record['status'])

    def test_committed_result_keeps_a_busy_unused_service_blocked(self):
        data = self.orphan('committed-unused-service')
        service = self.root / '.agent-1c/infobases' / ('vanessa-service-' + 'a' * 32)
        service.mkdir(parents=True)
        database = service / '1Cv8.1CD'
        database.write_bytes(b'fixture service database')
        with database.open('rb'):
            with self.assertRaisesRegex(WorkError, 'DATABASE_STILL_IN_USE'):
                recover_workflow_operation(self.coordinator.root, data['ticket'])

    def test_committed_result_waits_for_an_independent_database_handle(self):
        data = self.orphan('committed')
        with (Path(data['base']['path']) / '1Cv8.1CD').open('rb'):
            with self.assertRaisesRegex(WorkError, 'DATABASE_STILL_IN_USE'):
                recover_workflow_operation(self.coordinator.root, data['ticket'])
        with self.assertRaisesRegex(WorkError, 'RECOVERY_REQUIRED'):
            with Lease(self.coordinator.root, [data['base']], {}, timeout=0): pass


if __name__ == '__main__':
    unittest.main()
