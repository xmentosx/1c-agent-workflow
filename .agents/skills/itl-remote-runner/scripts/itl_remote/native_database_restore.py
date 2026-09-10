"""Restore an indexed DT under recovery ownership; never release the outer ticket."""
import json
import os
from pathlib import Path
import platform
import sys
import time
import uuid

from .common import OwnedProcess, WorkError, digest, read_json, write_json
from . import native_journal, restoration_context, restoration_journal


def _quiescent(coordinator, observations, manifest):
    absent = manifest.get('absentFileResources', [])
    allowed_absent = set(coordinator.resources(absent)) if absent else set()
    if not observations:
        raise WorkError('NATIVE_RECOVERY_DATABASE_STILL_IN_USE')
    for observation in observations:
        for sample in observation['observation']['samples']:
            for base in sample['resources']:
                unused_reservation = (not base['databasePresent'] and not base['directoryPresent'] and
                    coordinator.resources([base])[0] in allowed_absent)
                if base['sessionCount'] or not (base['databasePresent'] and base['exclusive'] or unused_reservation):
                    raise WorkError('NATIVE_RECOVERY_DATABASE_STILL_IN_USE')


def restore(recovery, original_key):
    from .native_recovery import inspect_native_work, _require_process_exited
    from .native_recovery_helpers import resolve, NAMES
    current = recovery._current()
    if current.get('owner', {}).get('operation') not in ('init-dev-branch-extension', 'release-e2e-extension-smoke'):
        raise WorkError('NATIVE_RECOVERY_DATABASE_OPERATION_CONTRACT_REQUIRED')
    journal = native_journal.inspect(recovery.coordinator, current, resolve_helpers=True)
    matches = [duty for duty in journal['restoration']['duties'] if duty['journalId'] + '/' + duty['id'] == original_key]
    if len(matches) != 1 or matches[0]['kind'] != 'infobase-snapshot' or matches[0]['status'] != 'pending':
        raise WorkError('NATIVE_RECOVERY_PENDING_DATABASE_DUTY_REQUIRED')
    duty = matches[0]
    helpers = journal['restoration']['helperGenerations'][original_key]
    if tuple(Path(item['path']).name for item in helpers['files']) != NAMES:
        raise WorkError('NATIVE_RECOVERY_DATABASE_RESTORE_HELPERS_UNAVAILABLE')
    # Every prior producer must be gone, including a previous failed recovery.
    for producer in native_journal._index(current)['producers'].values():
        if str(producer.get('hostName', '')).casefold() != platform.node().casefold():
            raise WorkError('NATIVE_RECOVERY_ORIGINAL_HOST_REQUIRED')
        _require_process_exited(producer.get('ownerPid'))
    restoration_journal._snapshot(recovery.coordinator, duty)
    manifest = restoration_context.read(recovery.coordinator, duty)
    observations = inspect_native_work(recovery, journal)
    _quiescent(recovery.coordinator, observations, manifest)
    from . import native_lifecycle_restore
    native_lifecycle_restore.prepare(recovery, duty)
    output = recovery.coordinator.root / 'recovery-observations' / recovery.ticket / recovery.attempt
    runtime = Path(__file__).resolve().parent.parent
    worker, bridge = runtime / 'Restore-NativeRecovery.ps1', runtime / 'DatabaseAccess.ps1'
    restore_id = uuid.uuid4().hex
    context = {'schemaVersion': 1, 'restoreId': restore_id, 'duty': duty, 'helpers': helpers,
               'bridge': {'path': str(bridge), 'sha256': digest(bridge)},
               'python': sys.executable, 'output': str(output)}
    context_path = output / (restore_id + '.context.json')
    log = output / (restore_id + '.log')
    write_json(context_path, context)
    worker_hash = digest(worker)
    shell = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
    private_input = (json.dumps(recovery.proof(), ensure_ascii=True) + '\n').encode('ascii')
    try:
        with OwnedProcess([str(shell), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(worker),
                           '-ContextPath', str(context_path)], output, log, input_data=private_input) as process:
            process.wait(3600, recovery.cancelled)
    except WorkError as error:
        raise WorkError('NATIVE_RECOVERY_DATABASE_RESTORE_FAILED: log=' + str(log) + '; ' + str(error)) from error
    finally:
        private_input = None
    if digest(worker) != worker_hash or digest(bridge) != context['bridge']['sha256']:
        raise WorkError('NATIVE_RECOVERY_RESTORE_IMPLEMENTATION_CHANGED')
    resolve(recovery.coordinator, helpers['files'])
    restoration_journal._snapshot(recovery.coordinator, duty)
    result_path = output / (restore_id + '.result.json')
    result = read_json(result_path)
    if (not isinstance(result, dict) or result.get('schemaVersion') != 1 or result.get('restoreId') != restore_id or
            result.get('originalDuty') != original_key or result.get('snapshotSha256') != duty['snapshotSha256'] or
            str(result.get('host', '')).casefold() != platform.node().casefold() or result.get('infoBase') != duty['infoBase']):
        raise WorkError('NATIVE_RECOVERY_DATABASE_RESTORE_UNCONFIRMED')
    restored_journal = native_journal.inspect(recovery.coordinator, recovery._current(), resolve_helpers=True)
    restored = [value for value in restored_journal['restoration']['duties']
                if value['journalId'] + '/' + value['id'] == result.get('restoredDuty')]
    native = [value for value in restored_journal['operations']
              if value['journalId'] + '/' + value['id'] == result.get('restoreOperation')]
    if (len(restored) != 1 or len(native) != 1 or restored[0]['status'] != 'restored' or
            restored[0]['snapshotSha256'] != duty['snapshotSha256'] or restored[0]['infoBase'] != duty['infoBase'] or
            restored[0]['restoreOperation'] != result.get('restoreOperation') or
            native[0]['purpose'] != 'designer-restore-snapshot-' + restored[0]['id'] or
            not native[0]['startAttempted'] or not native[0]['launcherExited'] or not native[0]['quiescenceConfirmed']):
        raise WorkError('NATIVE_RECOVERY_DATABASE_RESTORE_UNCONFIRMED')
    after = inspect_native_work(recovery, restored_journal)
    _quiescent(recovery.coordinator, after, manifest)
    evidence = {'result': result, 'path': str(result_path), 'sha256': digest(result_path),
                'workerSha256': worker_hash, 'before': observations, 'after': after}
    with recovery.coordinator.mutex(time.monotonic() + 30, recovery.cancelled):
        current = recovery._current()
        current['recoveryAttempts'][-1].setdefault('databaseRestorations', []).append(evidence)
        recovery.coordinator.save(current)
        recovery.record = current
    evidence['lifecycle'] = native_lifecycle_restore.complete(recovery, duty)
    return evidence
