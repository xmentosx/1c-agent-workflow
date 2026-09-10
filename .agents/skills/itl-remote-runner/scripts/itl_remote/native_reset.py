"""Authority-indexed reset phases; local branch state is not recovery proof."""
import copy
from pathlib import Path
import re
import time

from .common import WorkError, beneath, digest, identity, read_json, stamp, write_json
from . import native_journal as native, native_continuation


PHASES = ('archive-pending', 'archive-complete', 'git-reset-complete', 'runtime-initializing', 'complete')
STABLE = ('project', 'mainProject', 'branch', 'branchName', 'target', 'oldHead',
          'masterCommit', 'masterTree', 'masterFingerprint', 'masterConfigTree', 'archivePath', 'seed')


def assert_recovery_handoff(lease, record, parent):
    attempts = record.get('recoveryAttempts', [])
    authorized = attempts[-1].get('resetResume') if attempts else None
    if (lease.purpose != 'recovery' or record['status'] != 'recovering' or
            record.get('owner', {}).get('operation') != 'reset-dev-branch' or
            not isinstance(authorized, dict) or authorized.get('continuation') != parent):
        raise WorkError('NATIVE_CONTINUATION_PARENT_GENERATION_CHANGED')
    checkpoints = inspect(lease.coordinator, record)
    if not checkpoints or checkpoints[-1]['reference'] != authorized.get('checkpoint'):
        raise WorkError('NATIVE_RESET_RECOVERY_CHECKPOINT_CHANGED')


def validate(value):
    if (not isinstance(value, dict) or set(value) != {'schemaVersion', 'phase', 'newHead', 'archiveManifest', *STABLE} or
            value['schemaVersion'] != 1 or value['phase'] not in PHASES):
        raise WorkError('NATIVE_RESET_CONTEXT_INVALID')
    for name in ('project', 'mainProject', 'archivePath'):
        if not isinstance(value[name], str) or not Path(value[name]).is_absolute():
            raise WorkError('NATIVE_RESET_PATH_INVALID')
    for name in ('oldHead', 'masterCommit', 'masterTree', 'masterConfigTree'):
        if not isinstance(value[name], str) or not re.fullmatch('[a-f0-9]{40}|[a-f0-9]{64}', value[name]):
            raise WorkError('NATIVE_RESET_COMMIT_INVALID')
    if (not isinstance(value['branchName'], str) or not value['branchName'] or
            not isinstance(value['branch'], str) or not value['branch'].startswith('itldev/') or
            not isinstance(value['masterFingerprint'], str) or not value['masterFingerprint']):
        raise WorkError('NATIVE_RESET_BRANCH_INVALID')
    target = value['target']
    if (not isinstance(target, dict) or set(target) != {'kind', 'path'} or target['kind'] not in ('file', 'server') or
            not isinstance(target['path'], str) or not target['path']):
        raise WorkError('NATIVE_RESET_TARGET_INVALID')
    archive_root = Path(value['mainProject']) / '.agent-1c' / 'branch-archives'
    try:
        relative = Path(value['archivePath']).relative_to(archive_root)
        if not relative.parts or '..' in relative.parts:
            raise ValueError()
    except ValueError as error:
        raise WorkError('NATIVE_RESET_ARCHIVE_OUTSIDE_ROOT') from error
    seed = value['seed']
    fields = {'schemaVersion', 'sourceKey', 'syncId', 'artifactKind', 'artifactPath', 'artifactSha256',
              'artifactBytes', 'configurationFingerprint', 'baselinePath', 'baselineHash', 'baselineSha256'}
    if (not isinstance(seed, dict) or set(seed) != fields or seed['schemaVersion'] != 1 or
            seed['artifactKind'] not in ('file-1cd', 'server-dt') or
            type(seed['artifactBytes']) is not int or seed['artifactBytes'] <= 0 or
            any(not isinstance(seed[name], str) or not seed[name] for name in ('sourceKey', 'syncId')) or
            seed['configurationFingerprint'] != value['masterFingerprint'] or not isinstance(seed['baselineHash'], str)):
        raise WorkError('NATIVE_RESET_SEED_INVALID')
    for name in ('artifactPath', 'baselinePath'):
        if not isinstance(seed[name], str) or not Path(seed[name]).is_absolute():
            raise WorkError('NATIVE_RESET_SEED_INVALID')
    for name in ('artifactSha256', 'baselineSha256'):
        if not isinstance(seed[name], str) or not re.fullmatch('[a-f0-9]{64}', seed[name]):
            raise WorkError('NATIVE_RESET_SEED_INVALID')
    position = PHASES.index(value['phase'])
    if not isinstance(value['newHead'], str) or (position < 2 and value['newHead']) or (
            position >= 2 and not re.fullmatch('[a-f0-9]{40}|[a-f0-9]{64}', value['newHead'])):
        raise WorkError('NATIVE_RESET_HEAD_INVALID')
    manifest = value['archiveManifest']
    if position == 0:
        if manifest is not None:
            raise WorkError('NATIVE_RESET_ARCHIVE_PREMATURE')
    elif (not isinstance(manifest, dict) or set(manifest) != {'path', 'sha256'} or
          manifest['path'] != str(Path(value['archivePath']) / 'manifest.json') or
          not isinstance(manifest['sha256'], str) or not re.fullmatch('[a-f0-9]{64}', manifest['sha256'])):
        raise WorkError('NATIVE_RESET_ARCHIVE_INVALID')


def _transition(previous, value):
    if previous is None:
        if value['phase'] != PHASES[0]:
            raise WorkError('NATIVE_RESET_INITIAL_PHASE_REQUIRED')
        return
    if any(previous[name] != value[name] for name in STABLE):
        raise WorkError('NATIVE_RESET_PINNED_INPUT_CHANGED')
    before, after = PHASES.index(previous['phase']), PHASES.index(value['phase'])
    if after not in (before, before + 1) or before == len(PHASES) - 1:
        raise WorkError('NATIVE_RESET_PHASE_TRANSITION_INVALID')
    if (before == after and previous != value or
            before >= 1 and previous['archiveManifest'] != value['archiveManifest'] or
            before >= 2 and previous['newHead'] != value['newHead']):
        raise WorkError('NATIVE_RESET_PINNED_INPUT_CHANGED')


def inspect(coordinator, record):
    checkpoints = []
    for producer_id, producer in native._index(record)['producers'].items():
        entries = producer.get('resetCheckpoints', [])
        if not isinstance(entries, list):
            raise WorkError('NATIVE_RESET_INDEX_INVALID')
        for entry in entries:
            if (not isinstance(entry, dict) or set(entry) != {'path', 'sha256'} or
                    not isinstance(entry['sha256'], str) or not re.fullmatch('[a-f0-9]{64}', entry['sha256'])):
                raise WorkError('NATIVE_RESET_INDEX_INVALID')
            expected = Path('native-resets') / record['ticket'] / producer_id / (entry['sha256'] + '.json')
            if entry['path'] != expected.as_posix():
                raise WorkError('NATIVE_RESET_INDEX_INVALID')
            path = beneath(coordinator.root, entry['path'])
            if not path.is_file() or digest(path) != entry['sha256']:
                raise WorkError('NATIVE_RESET_CHECKPOINT_CHANGED')
            value = read_json(path)
            if (not isinstance(value, dict) or set(value) != {'schemaVersion', 'ticket', 'producerId', 'sequence',
                    'previous', 'continuation', 'recordedAt', 'context'} or value['schemaVersion'] != 1 or
                    value['ticket'] != record['ticket'] or value['producerId'] != producer_id or
                    type(value['sequence']) is not int or value['sequence'] < 1):
                raise WorkError('NATIVE_RESET_CHECKPOINT_INVALID')
            validate(value['context'])
            plan = native_continuation.read(coordinator, record, value['continuation'])['plan']
            if (record.get('owner', {}).get('operation') != 'reset-dev-branch' or
                    value['continuation']['producerId'] != producer_id or plan['operation'] != 'reset-dev-branch' or
                    Path(plan['project']) != Path(value['context']['project']) or
                    coordinator.resources([plan['target']]) != coordinator.resources([value['context']['target']])):
                raise WorkError('NATIVE_RESET_PLAN_CHANGED')
            checkpoints.append({'reference': {'ticket': record['ticket'], 'producerId': producer_id,
                                'sha256': entry['sha256']}, **value})
    checkpoints.sort(key=lambda value: value['sequence'])
    previous = None
    for number, checkpoint in enumerate(checkpoints, 1):
        if checkpoint['sequence'] != number or checkpoint['previous'] != (previous['reference'] if previous else None):
            raise WorkError('NATIVE_RESET_CHAIN_CHANGED')
        _transition(previous['context'] if previous else None, checkpoint['context'])
        previous = checkpoint
    return checkpoints


def publish(lease, producer_id, context):
    validate(context)
    lease.validate()
    with lease.coordinator.mutex(time.monotonic() + 30, lease.cancelled):
        record = native._current(lease)
        from .native_completion import assert_writable
        assert_writable(record, producer_id)
        producer = native._index(record)['producers'].get(producer_id)
        if (not producer or producer['participantId'] != lease.participant_id or
                producer['generation'] != identity(record['token']) or lease.owner.get('operation') != 'reset-dev-branch' or
                record.get('owner', {}).get('operation') != 'reset-dev-branch'):
            raise WorkError('NATIVE_RESET_OWNER_CHANGED')
        entry = producer.get('continuation')
        reference = {'ticket': record['ticket'], 'producerId': producer_id,
                     'sha256': entry.get('sha256') if isinstance(entry, dict) else None}
        plan = native_continuation.read(lease.coordinator, record, reference)['plan']
        if (Path(context['project']) != Path(plan['project']) or plan['operation'] != 'reset-dev-branch' or
                lease.coordinator.resources([context['target']]) != lease.coordinator.resources([plan['target']])):
            raise WorkError('NATIVE_RESET_PLAN_CHANGED')
        previous = inspect(lease.coordinator, record)
        last = previous[-1] if previous else None
        _transition(last['context'] if last else None, context)
        value = {'schemaVersion': 1, 'ticket': record['ticket'], 'producerId': producer_id,
                 'sequence': len(previous) + 1, 'previous': last['reference'] if last else None,
                 'continuation': reference, 'recordedAt': stamp(), 'context': copy.deepcopy(context)}
        temporary = beneath(lease.coordinator.root, 'native-resets/' + record['ticket'] + '/' + producer_id + '/pending.json')
        write_json(temporary, value)
        sha = digest(temporary)
        path = temporary.with_name(sha + '.json')
        temporary.replace(path)
        producer.setdefault('resetCheckpoints', []).append({'path': path.relative_to(lease.coordinator.root).as_posix(), 'sha256': sha})
        lease.coordinator.save(record)
        lease.record = record
        return {'event': 'reset-checkpoint-recorded', 'ticket': record['ticket'], 'producerId': producer_id,
                'sha256': sha, 'sequence': value['sequence'], 'phase': context['phase']}
