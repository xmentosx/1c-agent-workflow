"""Durable state/source reconciliation for interrupted extension initialization."""
import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
import uuid

from .common import WorkError, capture, digest, git_path_list, read_json, stamp, write_json
from . import restoration_context


def _bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')


def _hash(path):
    path = restoration_context._path(str(path))
    if path.exists() and not path.is_file():
        raise WorkError('NATIVE_RECOVERY_STATE_TARGET_INVALID')
    return digest(path) if path.exists() else None


def _atomic(path, content, allowed):
    path = restoration_context._path(str(path))
    if _hash(path) not in allowed:
        raise WorkError('NATIVE_RECOVERY_STATE_CHANGED_OUTSIDE_OPERATION')
    if content is None:
        if path.exists():
            path.unlink()
        return
    if not path.parent.is_dir():
        raise WorkError('NATIVE_RECOVERY_STATE_DIRECTORY_MISSING')
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.itl-recovery-', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        if _hash(path) not in allowed:
            raise WorkError('NATIVE_RECOVERY_STATE_CHANGED_OUTSIDE_OPERATION')
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def _tree(path):
    path = restoration_context._path(str(path))
    if not path.exists():
        return None
    if not path.is_dir():
        raise WorkError('NATIVE_RECOVERY_SOURCE_NOT_DIRECTORY')
    entries = []
    for directory, names, files in os.walk(path, followlinks=False):
        for name in sorted(names + files):
            item = restoration_context._path(str(Path(directory) / name))
            if item.is_dir():
                entries.append((item.relative_to(path).as_posix(), 'directory', ''))
            elif item.is_file():
                entries.append((item.relative_to(path).as_posix(), 'file', digest(item)))
            else:
                raise WorkError('NATIVE_RECOVERY_SOURCE_ENTRY_INVALID')
    return hashlib.sha256(_bytes(sorted(entries))).hexdigest()


def _reference(path):
    return {'path': str(path), 'sha256': digest(path)}


def _checkout(manifest):
    project = Path(manifest['project'])
    state = read_json(manifest['state']['snapshotPath'])
    branch = state.get('devBranch')
    if not branch and not (project / '.git').exists():
        return  # A standalone technical infobase has no Git checkout to alter.
    if not isinstance(branch, str) or not branch:
        raise WorkError('NATIVE_RECOVERY_CHECKOUT_BINDING_REQUIRED')
    actual = capture(['git', '-C', str(project), 'symbolic-ref', '--quiet', '--short', 'HEAD'], timeout=30).decode('utf-8').strip()
    if actual != branch:
        raise WorkError('NATIVE_RECOVERY_CHECKOUT_CHANGED')
    relative = Path(manifest['source']['path']).relative_to(project).as_posix()
    # Initialization requires an absent or empty source directory. It does not
    # commit or stage generated files. A tracked path now belongs to later Git
    # work and must not be moved as interrupted initialization output.
    if git_path_list(project, ['ls-files', '-z', '--', relative]):
        raise WorkError('NATIVE_RECOVERY_SOURCE_BECAME_TRACKED')


def _remember(recovery, entry):
    with recovery.coordinator.mutex(time.monotonic() + 30, recovery.cancelled):
        current = recovery._current()
        current['recoveryAttempts'][-1].setdefault('lifecycleRestorations', {})[entry['originalDuty']] = entry
        recovery.coordinator.save(current)
        recovery.record = current


def _load(recovery, duty):
    key = duty['journalId'] + '/' + duty['id']
    for attempt in reversed(recovery._current()['recoveryAttempts']):
        entry = attempt.get('lifecycleRestorations', {}).get(key)
        if entry is None:
            continue
        path = restoration_context._file(entry['plan']['path'], entry['plan']['sha256'])
        value = read_json(path)
        expected = Path(duty['project']) / '.agent-1c' / 'restoration-state' / recovery.ticket
        if (path.parent.parent != expected or value['originalDuty'] != key or
                value['manifestSha256'] != duty['recoveryContext']['sha256']):
            raise WorkError('NATIVE_RECOVERY_STATE_PLAN_BINDING_CHANGED')
        for name in ('preparedState', 'restoredState', 'interruptedState'):
            artifact = value[name]
            if Path(artifact['path']).parent != path.parent:
                raise WorkError('NATIVE_RECOVERY_STATE_PLAN_BINDING_CHANGED')
            restoration_context._file(artifact['path'], artifact['sha256'])
        if value['interruptedEnvironment'] is not None:
            artifact = value['interruptedEnvironment']
            if Path(artifact['path']).parent != path.parent:
                raise WorkError('NATIVE_RECOVERY_STATE_PLAN_BINDING_CHANGED')
            restoration_context._file(artifact['path'], artifact['sha256'])
        if Path(value['quarantine']) != path.parent / 'interrupted-source':
            raise WorkError('NATIVE_RECOVERY_STATE_PLAN_BINDING_CHANGED')
        return copy.deepcopy(entry), value
    return None, None


def prepare(recovery, duty):
    """Invalidate success receipts durably before any database bytes change."""
    recovery.proof()
    if recovery.cancelled():
        raise WorkError('INFOBASE_ACCESS_CANCELLED')
    manifest = restoration_context.read(recovery.coordinator, duty)
    _checkout(manifest)
    entry, plan = _load(recovery, duty)
    if plan is None:
        state_path = Path(manifest['state']['destination'])
        current_bytes = state_path.read_bytes()
        current = json.loads(current_bytes.decode('utf-8-sig'))
        baseline = read_json(manifest['state']['snapshotPath'])
        if not isinstance(current, dict):
            raise WorkError('NATIVE_RECOVERY_STATE_TARGET_CHANGED')
        for field in ('worktreePath', 'safeDevBranchName', 'infoBaseKind', 'devBranchInfoBasePath'):
            if current.get(field) != baseline.get(field):
                raise WorkError('NATIVE_RECOVERY_STATE_TARGET_CHANGED')
        operation = recovery._current()['owner']['operation']
        if operation not in ('init-dev-branch-extension', 'release-e2e-extension-smoke'):
            raise WorkError('NATIVE_RECOVERY_STATE_OPERATION_REQUIRED')
        from .native_recovery import _require_process_exited
        for field in ('roctupMcpPid', 'vanessaMcpPid'):
            pid = current.get(field)
            if pid not in (None, '', 0):
                try:
                    _require_process_exited(int(pid))
                except (ValueError, TypeError, WorkError) as error:
                    raise WorkError('NATIVE_RECOVERY_RUNTIME_STOP_UNCONFIRMED: ' + field) from error
        timestamp = stamp()
        restored = copy.deepcopy(baseline)
        restored.update(toolingInfoBaseGeneration=uuid.uuid4().hex, toolingInvalidatedAt=timestamp,
                        toolingInvalidationReason='interrupted-extension-restoration',
                        vanessaMcpSafeModeProof=None, yaxunitInstallationProof=None,
                        loadReason='restore-invalidated', designerInvoked=False, enterpriseInvoked=False,
                        enterpriseNormalizationStatus='pending', enterpriseNormalizationReason='extension-init-rollback',
                        lastVerificationStatus='stale', lastVerificationStaleAt=timestamp,
                        lastVerificationStaleReason='interrupted-extension-restoration',
                        roctupMcpPid='', roctupMcpStatus='stopped',
                        vanessaMcpPid='', vanessaMcpStatus='stopped',
                        restorationStatus='restored', restorationTicket=recovery.ticket)
        for field in ('lastConfigDesignerFingerprint', 'lastConfigDesignerTreeObjectId', 'lastConfigDesignerLoadedAt',
                      'lastExtensionDesignerFingerprint', 'lastExtensionDesignerTreeObjectId',
                      'lastExtensionDesignerLoadedAt', 'sourceFingerprint'):
            restored[field] = ''
        if operation == 'init-dev-branch-extension':
            restored.update(extensionInitializationStatus='failed',
                            extensionInitializationError='Initialization was interrupted; its snapshot was restored.',
                            extensionInitializationUpdatedAt=timestamp)
        prepared = copy.deepcopy(restored)
        prepared['restorationStatus'] = 'pending'
        if operation == 'init-dev-branch-extension':
            prepared['extensionInitializationError'] = 'Initialization was interrupted; snapshot restoration is pending.'
        directory = restoration_context._path(str(Path(duty['project']) / '.agent-1c' / 'restoration-state' / recovery.ticket / uuid.uuid4().hex))
        directory.mkdir(parents=True)
        # Preserve the interrupted files locally, including any user edits.
        # Only their references enter the shared coordinator record.
        (directory / 'interrupted-state.json').write_bytes(current_bytes)
        (directory / 'prepared-state.json').write_bytes(_bytes(prepared))
        (directory / 'restored-state.json').write_bytes(_bytes(restored))
        environment = Path(manifest['environment']['destination'])
        environment_hash = _hash(environment)
        if environment_hash is not None:
            (directory / 'interrupted.env').write_bytes(environment.read_bytes())
        plan = {'schemaVersion': 1, 'originalDuty': duty['journalId'] + '/' + duty['id'],
                'manifestSha256': duty['recoveryContext']['sha256'],
                'preparedState': _reference(directory / 'prepared-state.json'),
                'restoredState': _reference(directory / 'restored-state.json'),
                'interruptedState': _reference(directory / 'interrupted-state.json'),
                'interruptedEnvironment': _reference(directory / 'interrupted.env') if environment_hash is not None else None,
                'sourceDigest': _tree(manifest['source']['path']), 'quarantine': str(directory / 'interrupted-source')}
        plan_path = directory / 'plan.json'
        write_json(plan_path, plan)
        entry = {'originalDuty': plan['originalDuty'], 'plan': _reference(plan_path), 'phase': 'prepared'}
        _remember(recovery, entry)
    allowed = {plan[name]['sha256'] for name in ('interruptedState', 'preparedState', 'restoredState')}
    _atomic(manifest['state']['destination'], Path(plan['preparedState']['path']).read_bytes(), allowed)
    entry['phase'] = 'state-invalidated'
    _remember(recovery, entry)
    return entry


def complete(recovery, duty):
    """Restore source/environment and publish state only after indexed DT proof."""
    recovery.proof()
    if recovery.cancelled():
        raise WorkError('INFOBASE_ACCESS_CANCELLED')
    manifest = restoration_context.read(recovery.coordinator, duty)
    _checkout(manifest)
    entry, plan = _load(recovery, duty)
    if plan is None:
        raise WorkError('NATIVE_RECOVERY_STATE_PLAN_REQUIRED')
    evidence = recovery._current()['recoveryAttempts'][-1].get('databaseRestorations', [])
    if not any(item.get('result', {}).get('originalDuty') == plan['originalDuty'] and
               item['result'].get('snapshotSha256') == duty['snapshotSha256'] for item in evidence):
        raise WorkError('NATIVE_RECOVERY_STATE_DATABASE_PROOF_REQUIRED')
    source = Path(manifest['source']['path'])
    quarantine = Path(plan['quarantine'])
    current_tree, kept_tree = _tree(source), _tree(quarantine)
    empty = hashlib.sha256(_bytes([])).hexdigest()
    original_tree = empty if manifest['source']['existed'] else None
    if kept_tree is not None:
        if kept_tree != plan['sourceDigest'] or current_tree not in (None, original_tree):
            raise WorkError('NATIVE_RECOVERY_SOURCE_CHANGED_OUTSIDE_OPERATION')
    elif current_tree != plan['sourceDigest'] and not (plan['sourceDigest'] is None and current_tree == original_tree):
        raise WorkError('NATIVE_RECOVERY_SOURCE_CHANGED_OUTSIDE_OPERATION')
    environment = Path(manifest['environment']['destination'])
    original_env = manifest['environment']['sha256'] if manifest['environment']['existed'] else None
    interrupted_env = plan['interruptedEnvironment']['sha256'] if plan['interruptedEnvironment'] else None
    if _hash(environment) not in (original_env, interrupted_env):
        raise WorkError('NATIVE_RECOVERY_STATE_CHANGED_OUTSIDE_OPERATION')
    if _hash(manifest['state']['destination']) not in (plan['preparedState']['sha256'], plan['restoredState']['sha256']):
        raise WorkError('NATIVE_RECOVERY_STATE_CHANGED_OUTSIDE_OPERATION')
    if kept_tree is None and current_tree is not None and plan['sourceDigest'] is not None:
        # Both absolute paths were checked against this captured project's
        # source and restoration roots. Rename preserves every original byte.
        os.rename(source, quarantine)
        if _tree(quarantine) != plan['sourceDigest']:
            raise WorkError('NATIVE_RECOVERY_SOURCE_CHANGED_OUTSIDE_OPERATION')
    if manifest['source']['existed']:
        source.mkdir(parents=True, exist_ok=True)
    if recovery.cancelled():
        raise WorkError('INFOBASE_ACCESS_CANCELLED')
    original_bytes = Path(manifest['environment']['snapshotPath']).read_bytes() if manifest['environment']['existed'] else None
    _atomic(environment, original_bytes, {original_env, interrupted_env})
    _atomic(manifest['state']['destination'], Path(plan['restoredState']['path']).read_bytes(),
            {plan['preparedState']['sha256'], plan['restoredState']['sha256']})
    if (_tree(source) != original_tree or _hash(environment) != original_env or
            _hash(manifest['state']['destination']) != plan['restoredState']['sha256']):
        raise WorkError('NATIVE_RECOVERY_LIFECYCLE_RESTORATION_UNCONFIRMED')
    entry.update(phase='restored', stateSha256=plan['restoredState']['sha256'],
                 environmentSha256=original_env, quarantine=plan['quarantine'] if _tree(quarantine) is not None else None)
    _remember(recovery, entry)
    return entry
