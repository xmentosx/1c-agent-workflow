"""Script-owned reconciliation of interrupted workflow operations.

The original journal stays immutable. Started native work requires its own live
operation adapter; this path never turns a saved quiescence flag into proof.
"""
from __future__ import annotations

import argparse
import ctypes
from datetime import datetime
import json
import os
from pathlib import Path
import platform
import re
import tempfile
import time
import uuid

from .access_recovery import Recovery, VerifiedRecovery, plan
from .common import OwnedProcess, WorkError, digest, write_json
from . import native_journal, restoration_journal

WORKFLOW_OPERATIONS = frozenset({
    'update-dev-branch-base', 'lock-config-repository-objects', 'check-dev-branch',
    'verify-dev-branch', 'update-auxiliary-contour', 'check-auxiliary-contour',
    'dump-auxiliary-contour', 'export-auxiliary-contour-result', 'reset-auxiliary-contour',
    'export-dev-branch-result', 'dump-dev-branch-extension', 'repair-dev-branch-tooling',
    'init-dev-branch-extension', 'release-e2e-extension-smoke',
    'reset-dev-branch', 'refresh-dev-branch-lite', 'refresh-dev-branch', 'sync-master',
    'update1cbase', 'loadfrom1cbase', 'getconfigfiles', 'deploy-and-test', 'sync-dev-branches',
})


def inspect_native_work(recovery, journal):
    """Observe current local work under recovery ownership, without stopping it."""
    if os.name != 'nt':
        raise WorkError('NATIVE_RECOVERY_WINDOWS_INSPECTION_REQUIRED')
    resources = {}
    generations = journal['helperGenerations']
    for operation in journal['operations']:
        for base in operation['resources']:
            key = recovery.coordinator.resources([base])[0]
            resources[key] = base
    for duty in journal['restoration']['duties']:
        for base in duty['resources']:
            key = recovery.coordinator.resources([base])[0]
            resources[key] = base
    continuations = journal.get('continuations', {})
    for continuation in continuations.values():
        for base in continuation['plan']['bases']:
            key = recovery.coordinator.resources([base])[0]
            resources[key] = base
    if not resources or not (generations or journal['restoration']['helperGenerations'] or continuations):
        raise WorkError('NATIVE_RECOVERY_NATIVE_CONTEXT_REQUIRED')
    if any(base['kind'] != 'file' for base in resources.values()):
        raise WorkError('NATIVE_RECOVERY_SERVER_INSPECTION_REQUIRED')
    # Scope matching belongs to the generation which produced it. Running one
    # worker per generation also keeps an update from interpreting old records
    # through unrelated current helper code.
    grouped = {}
    for operation in journal['operations']:
        helpers = generations[operation['journalId'] + '/' + operation['id']]
        group = grouped.setdefault(helpers['generation'], {'helpers': helpers, 'scopes': [], 'project': operation['project']})
        group['scopes'].extend(operation['ownedProcessScopes'])
    for duty in journal['restoration']['duties']:
        helpers = journal['restoration']['helperGenerations'][duty['journalId'] + '/' + duty['id']]
        grouped.setdefault(helpers['generation'], {'helpers': helpers, 'scopes': [], 'project': duty['project']})
    for producer_id, continuation in continuations.items():
        helpers = journal['continuationHelperGenerations'][producer_id]
        grouped.setdefault(helpers['generation'], {'helpers': helpers, 'scopes': [], 'project': continuation['plan']['project']})
    observations = []
    output = recovery.coordinator.root / 'recovery-observations' / recovery.ticket / recovery.attempt
    output.mkdir(parents=True, exist_ok=True)
    worker = Path(__file__).resolve().parent.parent / 'Inspect-NativeRecovery.ps1'
    shell = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
    for generation, group in grouped.items():
        recovery.proof()
        if recovery.cancelled():
            raise WorkError('INFOBASE_ACCESS_CANCELLED')
        context = {'schemaVersion': 1, 'observationId': uuid.uuid4().hex, 'resources': list(resources.values()), **group}
        prefix = generation + '-' + context['observationId']
        context_path = output / (prefix + '.context.json')
        log = output / (prefix + '.observation.json')
        write_json(context_path, context)
        worker_hash = digest(worker)
        started = time.monotonic()
        try:
            with OwnedProcess([str(shell), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(worker),
                               '-ContextPath', str(context_path)], output, log) as process:
                process.wait(45, recovery.cancelled)
        except WorkError as error:
            raise WorkError('NATIVE_RECOVERY_INSPECTION_FAILED: log=' + str(log) + '; ' + str(error)) from error
        if digest(worker) != worker_hash:
            raise WorkError('NATIVE_RECOVERY_INSPECTION_IMPLEMENTATION_CHANGED')
        from .native_recovery_helpers import resolve
        resolve(recovery.coordinator, group['helpers']['files'])
        value = json.loads(log.read_text(encoding='utf-8-sig'))
        if (value.get('schemaVersion') != 1 or value.get('observationId') != context['observationId'] or
                str(value.get('host', '')).casefold() != platform.node().casefold() or
                not isinstance(value.get('samples'), list) or len(value['samples']) != 2 or
                time.monotonic() - started < 1):
            raise WorkError('NATIVE_RECOVERY_INSPECTION_UNCONFIRMED')
        for sample in value['samples']:
            actual = sample.get('resources')
            if not isinstance(actual, list) or len(actual) != len(resources):
                raise WorkError('NATIVE_RECOVERY_INSPECTION_SCOPE_CHANGED')
            if recovery.coordinator.resources(actual) != sorted(resources):
                raise WorkError('NATIVE_RECOVERY_INSPECTION_SCOPE_CHANGED')
            for base in actual:
                if (type(base.get('sessionCount')) is not int or base['sessionCount'] < 0 or
                        type(base.get('exclusive')) is not bool or type(base.get('databasePresent')) is not bool or
                        type(base.get('directoryPresent')) is not bool):
                    raise WorkError('NATIVE_RECOVERY_INSPECTION_UNCONFIRMED')
        observations.append({'path': str(log), 'sha256': digest(log), 'workerSha256': worker_hash,
                             'generation': generation, 'observation': value})
    return observations


def _require_process_exited(pid):
    if type(pid) is not int or pid <= 0:
        raise WorkError('NATIVE_RECOVERY_PRODUCER_IDENTITY_REQUIRED')
    if os.name == 'nt':
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.argtypes = (ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32)
        kernel.OpenProcess.restype = ctypes.c_void_p
        kernel.WaitForSingleObject.argtypes = (ctypes.c_void_p, ctypes.c_uint32)
        kernel.WaitForSingleObject.restype = ctypes.c_uint32
        kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
        handle = kernel.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE only.
        if not handle:
            if ctypes.get_last_error() == 87:  # ERROR_INVALID_PARAMETER: no PID.
                return
            raise WorkError('NATIVE_RECOVERY_PRODUCER_INSPECTION_FAILED')
        try:
            state = kernel.WaitForSingleObject(handle, 0)
        finally:
            kernel.CloseHandle(handle)
        if state == 0:
            return
        if state != 258:  # WAIT_TIMEOUT means the producer is still running.
            raise WorkError('NATIVE_RECOVERY_PRODUCER_INSPECTION_FAILED')
    else:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        except PermissionError as error:
            raise WorkError('NATIVE_RECOVERY_PRODUCER_INSPECTION_FAILED') from error
    # A reused PID is conservatively treated as live; never stop it.
    raise WorkError('NATIVE_RECOVERY_PRODUCER_STILL_RUNNING')


def _destination(value):
    root, path = Path(value['project']), Path(value['destination'])
    if not root.is_absolute() or not path.is_absolute() or not path.is_relative_to(root):
        raise WorkError('NATIVE_RECOVERY_SOURCE_SCOPE_CHANGED')
    if '..' in path.parts or '..' in root.parts:
        raise WorkError('NATIVE_RECOVERY_SOURCE_SCOPE_CHANGED')
    for component in (root, *path.relative_to(root).parents):
        candidate = component if component.is_absolute() else root / component
        if candidate.is_symlink() or getattr(candidate, 'is_junction', lambda: False)():
            raise WorkError('NATIVE_RECOVERY_SOURCE_REDIRECTED')
    if path.is_symlink() or getattr(path, 'is_junction', lambda: False)():
        raise WorkError('NATIVE_RECOVERY_SOURCE_REDIRECTED')
    if not path.parent.is_dir():
        raise WorkError('NATIVE_RECOVERY_SOURCE_DIRECTORY_MISSING')
    return path


def _restore_cursor(coordinator, value):
    path = _destination(value)
    if value['existed']:
        restoration_journal._snapshot(coordinator, value)
        original = Path(value['snapshotPath']).read_bytes()
        import hashlib
        if hashlib.sha256(original).hexdigest() != value['snapshotSha256']:
            raise WorkError('RESTORATION_JOURNAL_SNAPSHOT_CHANGED')
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.itl-restore-', delete=False) as stream:
                temporary = Path(stream.name)
                stream.write(original)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            if temporary is not None and temporary.exists():
                temporary.unlink()
    elif path.exists():
        path.unlink()
    restoration_journal._restored(value)
    return {'duty': value['journalId'] + '/' + value['id'], 'destination': str(path),
            'existed': value['existed'], 'sha256': digest(path) if value['existed'] else None}


def recover_workflow_operation(root, ticket, *, cancelled=lambda: False):
    """Reconcile preparation, repository capture or extension snapshot rollback.

No old lease is reused and the original business workload is never replayed.
An unsupported later phase remains needs-attention for its operation adapter.
"""
    prepared = plan(root, ticket)
    with Recovery(root, ticket, prepared['revision'], {'operation': 'workflow-native-recovery'}, cancelled=cancelled) as recovery:
        def verify(_operation):
            if cancelled():
                raise WorkError('INFOBASE_ACCESS_CANCELLED')
            current = recovery._current()
            if current.get('owner', {}).get('operation') not in WORKFLOW_OPERATIONS:
                raise WorkError('NATIVE_RECOVERY_OPERATION_CONTRACT_REQUIRED')
            journal = native_journal.inspect(recovery.coordinator, current, resolve_helpers=True)
            if journal['restoration']['protocol'] != 'available':
                raise WorkError('NATIVE_RECOVERY_RESTORATION_CONTRACT_REQUIRED')
            producers = native_journal._index(current)['producers']
            read_only_dump = False
            observed = []
            for producer in producers.values():
                if str(producer.get('hostName', '')).casefold() != platform.node().casefold():
                    raise WorkError('NATIVE_RECOVERY_ORIGINAL_HOST_REQUIRED')
                _require_process_exited(producer.get('ownerPid'))
                observed.append({'host': producer['hostName'], 'pid': producer['ownerPid'], 'state': 'exited'})
            if any(producer['participantId'] is None and producer.get('completion') for producer in producers.values()):
                from .native_completion import recover_completed
                observations = inspect_native_work(recovery, journal)
                return recover_completed(recovery, journal, observed, observations)
            if journal['resetCheckpoints']:
                from .native_reset_resume import recover
                return recover(recovery, journal, observed)
            if current['owner']['operation'] == 'sync-dev-branches' and journal.get('sourceSyncPhases'):
                from .native_source_sync import recover
                observations = inspect_native_work(recovery, journal)
                return recover(recovery, journal, observed, observations)
            if current['owner']['operation'] in ('init-dev-branch-extension', 'release-e2e-extension-smoke') and any(
                    duty['kind'] == 'infobase-snapshot' and duty['status'] == 'pending'
                    for duty in journal['restoration']['duties']):
                return _recover_extension_snapshots(recovery, journal, observed)
            if any(operation['startAttempted'] for operation in journal['operations']):
                observations = inspect_native_work(recovery, journal)
                with recovery.coordinator.mutex(time.monotonic() + 30, recovery.cancelled):
                    inspected = recovery._current()
                    inspected['recoveryAttempts'][-1]['nativeObservations'] = observations
                    recovery.coordinator.save(inspected)
                    recovery.record = inspected
                if current['owner']['operation'] == 'init-dev-branch-extension' and any(
                        duty['kind'] == 'infobase-snapshot' and duty['status'] == 'committed'
                        for duty in journal['restoration']['duties']):
                    from .native_completion_recovery import committed_initialization
                    return committed_initialization(recovery, journal, observed, observations)
                # Repository capture intentionally retains its object claims.
                # Reconciliation releases only database admission; it neither
                # unlocks objects nor pretends the interrupted report succeeded.
                repository_capture = current['owner']['operation'] == 'lock-config-repository-objects' and all(
                    operation['purpose'] == 'designer-designer-command' for operation in journal['operations'])
                # These public routes only dump existing configuration files.
                # Both the owning operation and every native purpose must match:
                # a generic Designer command or a later write is not a dump.
                read_only_dump = current['owner']['operation'] in (
                    'loadfrom1cbase', 'getconfigfiles', 'dump-dev-branch-extension') and all(
                    operation['purpose'] == 'designer-dump-config-to-files' for operation in journal['operations'])
                if not repository_capture and not read_only_dump:
                    raise WorkError('NATIVE_RECOVERY_STARTED_OPERATION_ADAPTER_REQUIRED')
                if not observations or any(
                        base['sessionCount'] or not base['databasePresent'] or not base['exclusive']
                        for observation in observations for sample in observation['observation']['samples'] for base in sample['resources']):
                    raise WorkError('NATIVE_RECOVERY_DATABASE_STILL_IN_USE')
            else:
                observations = []
            duties = journal['restoration']['duties']
            if any(value['kind'] != 'config-dump-info' for value in duties):
                raise WorkError('NATIVE_RECOVERY_DATABASE_RESTORATION_ADAPTER_REQUIRED')
            # Validate every pending input before applying the first restore.
            pending = [value for value in duties if value['status'] == 'pending']
            destinations = {}
            for value in pending:
                destination = str(_destination(value)).casefold() if os.name == 'nt' else str(_destination(value))
                try:
                    created = datetime.fromisoformat(value['createdAt'])
                    if created.tzinfo is None:
                        raise ValueError('timezone required')
                except ValueError as error:
                    raise WorkError('NATIVE_RECOVERY_SNAPSHOT_ORDER_UNKNOWN') from error
                destinations.setdefault(destination, []).append((created, value))
                if value['existed']:
                    restoration_journal._snapshot(recovery.coordinator, value)
            originals = []
            for values in destinations.values():
                values.sort(key=lambda item: item[0])
                earliest, original = values[0]
                if any(created == earliest and (value['existed'], value['snapshotSha256']) !=
                       (original['existed'], original['snapshotSha256']) for created, value in values):
                    raise WorkError('NATIVE_RECOVERY_SNAPSHOT_ORDER_UNKNOWN')
                originals.append(original)
            restored = []
            # The oldest unresolved snapshot is the outer scope. Restoring it
            # directly is repeatable even if a prior recovery was interrupted.
            for value in originals:
                recovery.proof()
                if cancelled():
                    raise WorkError('INFOBASE_ACCESS_CANCELLED')
                restored.append(_restore_cursor(recovery.coordinator, value))
            if cancelled():
                raise WorkError('INFOBASE_ACCESS_CANCELLED')
            return VerifiedRecovery(tuple(current['resources']), {
                'adapter': ('workflow-read-only-dump' if read_only_dump else
                            'workflow-repository-capture' if observations else 'workflow-preparation'),
                'nativeStartAttempted': bool(observations),
                'producers': observed, 'restorations': restored,
                'originalRecordRevision': journal['recordRevision'], 'originalOutcome': 'interrupted',
                'nativeObservations': observations,
                'repositoryClaims': ('not changed by read-only dump' if read_only_dump else
                                     'retained; capture report remains interrupted' if observations else 'not changed by native work'),
                'resultAcceptance': ('dump remains interrupted; staged source and artifacts are preserved, not accepted; rerun the original helper'
                                     if read_only_dump else 'no new success or verification claim'),
            })
        return recovery.complete(verify)


def _recover_extension_snapshots(recovery, journal, producers):
    from . import restoration_context
    from .native_database_restore import restore
    duties = journal['restoration']['duties']
    originals = {}
    # The earliest pending database snapshot is the outer extension scope.
    # Inner committed smoke steps cannot supersede its required rollback.
    for duty in duties:
        if duty['kind'] != 'infobase-snapshot' or duty['status'] != 'pending':
            continue
        restoration_journal._snapshot(recovery.coordinator, duty)
        manifest = restoration_context.read(recovery.coordinator, duty)
        try:
            created = datetime.fromisoformat(duty['createdAt'])
            if created.tzinfo is None:
                raise ValueError('timezone required')
        except ValueError as error:
            raise WorkError('NATIVE_RECOVERY_SNAPSHOT_ORDER_UNKNOWN') from error
        resource = recovery.coordinator.resources([duty['infoBase']])[0]
        previous = originals.get(resource)
        if previous and previous[0] == created and previous[1]['snapshotSha256'] != duty['snapshotSha256']:
            raise WorkError('NATIVE_RECOVERY_SNAPSHOT_ORDER_UNKNOWN')
        if previous is None or created < previous[0]:
            originals[resource] = (created, duty, manifest)
    cursors, superseded = {}, []
    for operation in journal['operations']:
        if not operation['startAttempted']:
            continue
        for base in operation['admissions']:
            resource = recovery.coordinator.resources([base])[0]
            if resource in originals:
                continue
            path = Path(base['path'])
            # A service generation is disposable tooling, never another
            # business database. Its sessions still require live quiescence.
            managed_service = (base['kind'] == 'file' and
                path.parent == Path(operation['project']) / '.agent-1c' / 'infobases' and
                re.fullmatch(r'vanessa-service-[a-f0-9]{32}', path.name))
            if not managed_service:
                raise WorkError('NATIVE_RECOVERY_ADDITIONAL_DATABASE_RESTORATION_REQUIRED')
    for duty in duties:
        if duty['kind'] != 'config-dump-info' or duty['status'] != 'pending':
            continue
        if duty['existed']:
            restoration_journal._snapshot(recovery.coordinator, duty)
        destination = Path(duty['destination'])
        outer = next((value for value in originals.values()
                      if destination.is_relative_to(Path(value[2]['source']['path']))), None)
        if outer is not None:
            superseded.append({'duty': duty['journalId'] + '/' + duty['id'],
                               'restoredByOuterSourceScope': outer[1]['journalId'] + '/' + outer[1]['id']})
            continue
        _destination(duty)
        try:
            created = datetime.fromisoformat(duty['createdAt'])
            if created.tzinfo is None:
                raise ValueError('timezone required')
        except ValueError as error:
            raise WorkError('NATIVE_RECOVERY_SNAPSHOT_ORDER_UNKNOWN') from error
        previous = cursors.get(destination)
        if previous and created == previous[0] and (duty['existed'], duty['snapshotSha256']) != (previous[1]['existed'], previous[1]['snapshotSha256']):
            raise WorkError('NATIVE_RECOVERY_SNAPSHOT_ORDER_UNKNOWN')
        if previous is None or created < previous[0]:
            cursors[destination] = (created, duty)
    restorations = []
    for _, duty, _ in originals.values():
        restorations.append(restore(recovery, duty['journalId'] + '/' + duty['id']))
    for _, duty in cursors.values():
        recovery.proof()
        if recovery.cancelled():
            raise WorkError('INFOBASE_ACCESS_CANCELLED')
        restorations.append(_restore_cursor(recovery.coordinator, duty))
    if recovery.cancelled():
        raise WorkError('INFOBASE_ACCESS_CANCELLED')
    return VerifiedRecovery(tuple(recovery._current()['resources']), {
        'adapter': 'workflow-extension-snapshot', 'originalOutcome': 'interrupted',
        'producers': producers, 'restorations': restorations, 'supersededCursors': superseded,
        'originalRecordRevision': journal['recordRevision'],
        'toolingAndVerification': 'invalidated; native restoration is not fresh verification',
    })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--coordinator', required=True)
    parser.add_argument('--ticket', required=True)
    args = parser.parse_args()
    try:
        result = recover_workflow_operation(args.coordinator, args.ticket)
    except WorkError as error:
        print(json.dumps({'status': 'needs-attention', 'error': str(error)}, ensure_ascii=True))
        return 1
    print(json.dumps(result, ensure_ascii=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
