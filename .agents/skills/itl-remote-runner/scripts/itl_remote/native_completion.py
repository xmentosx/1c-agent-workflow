"""Acknowledge finished lifecycle work without turning it into release proof."""
from pathlib import Path
import copy
import re
import time

from .common import WorkError, beneath, digest, identity, read_json, stamp, write_json
from . import native_journal as native

OPERATIONS = frozenset({'sync-master', 'reset-dev-branch', 'refresh-dev-branch', 'refresh-dev-branch-lite',
                        'initialize-dev-branch-runtime', 'adopt-dev-worktree', 'new-dev-branch',
                        'new-extension-dev-branch', 'fork-dev-branch', 'init-project'})


def assert_writable(record, producer_id=None):
    producers = native._index(record)['producers']
    for key, producer in producers.items():
        if producer.get('completion') and (key == producer_id or producer.get('participantId') is None):
            raise WorkError('NATIVE_LIFECYCLE_ALREADY_COMPLETED')


def _snapshot(record, producer_id):
    producers = native._index(record)['producers']
    producer = producers[producer_id]
    selected = producers if producer['participantId'] is None else {producer_id: producer}
    return {key: {name: copy.deepcopy(value) for name, value in item.items() if name != 'completion'}
            for key, item in selected.items()}


def read(coordinator, record, producer_id):
    producer = native._index(record)['producers'][producer_id]
    entry = producer.get('completion')
    if (not isinstance(entry, dict) or set(entry) != {'path', 'sha256'} or
            not isinstance(entry['sha256'], str) or not re.fullmatch('[a-f0-9]{64}', entry['sha256'])):
        raise WorkError('NATIVE_LIFECYCLE_COMPLETION_INVALID')
    expected = Path('native-completions') / record['ticket'] / producer_id / (entry['sha256'] + '.json')
    if entry['path'] != expected.as_posix():
        raise WorkError('NATIVE_LIFECYCLE_COMPLETION_CHANGED')
    path = beneath(coordinator.root, entry['path'])
    if not path.is_file() or digest(path) != entry['sha256']:
        raise WorkError('NATIVE_LIFECYCLE_COMPLETION_CHANGED')
    value = read_json(path)
    if (not isinstance(value, dict) or set(value) != {'schemaVersion', 'ticket', 'producerId', 'operation',
            'project', 'resources', 'completedAt', 'continuation', 'journalSha256'} or value['schemaVersion'] != 1 or
            value['ticket'] != record['ticket'] or value['producerId'] != producer_id or
            value['operation'] not in OPERATIONS or value['resources'] != producer['resources'] or
            value['journalSha256'] != identity(_snapshot(record, producer_id))):
        raise WorkError('NATIVE_LIFECYCLE_COMPLETION_CHANGED')
    from .native_continuation import read as read_plan
    plan = read_plan(coordinator, record, value['continuation'])['plan']
    if value['operation'] != plan['operation'] or value['project'] != plan['project']:
        raise WorkError('NATIVE_LIFECYCLE_COMPLETION_CHANGED')
    return value


def publish(lease, producer_id):
    lease.validate()
    with lease.coordinator.mutex(time.monotonic() + 30, lease.cancelled):
        record = native._current(lease)
        producer = native._index(record)['producers'].get(producer_id)
        if (not producer or producer['participantId'] != lease.participant_id or
                producer['generation'] != identity(record['token'])):
            raise WorkError('NATIVE_LIFECYCLE_COMPLETION_OWNER_CHANGED')
        assert_writable(record, producer_id)
        from .native_continuation import read as read_plan
        entry = producer.get('continuation')
        reference = {'ticket': record['ticket'], 'producerId': producer_id,
                     'sha256': entry.get('sha256') if isinstance(entry, dict) else None}
        plan = read_plan(lease.coordinator, record, reference)['plan']
        if plan['operation'] not in OPERATIONS:
            raise WorkError('NATIVE_LIFECYCLE_COMPLETION_OPERATION_UNSUPPORTED')
        inspected = native.inspect(lease.coordinator, record)
        if inspected['resetCheckpoints'] and inspected['resetCheckpoints'][-1]['context']['phase'] != 'complete':
            raise WorkError('NATIVE_LIFECYCLE_COMPLETION_RESET_PENDING')
        selected = _snapshot(record, producer_id)
        if producer['participantId'] is None and any(p.get('status') == 'active' for p in native.participants(record).values()):
            raise WorkError('NATIVE_LIFECYCLE_COMPLETION_PARTICIPANTS_ACTIVE')
        selected_journals = {key for item in selected.values() for key in item['records']}
        for operation in inspected['operations']:
            if operation['journalId'] + '/' + operation['id'] in selected_journals and operation['startAttempted'] and not operation['quiescenceConfirmed']:
                raise WorkError('NATIVE_LIFECYCLE_COMPLETION_NATIVE_WORK_PENDING')
        selected_duties = {key for item in selected.values() for key in item.get('restorations', {})}
        for duty in inspected['restoration']['duties']:
            if duty['journalId'] + '/' + duty['id'] in selected_duties and duty['status'] == 'pending':
                raise WorkError('NATIVE_LIFECYCLE_COMPLETION_RESTORATION_PENDING')
        value = {'schemaVersion': 1, 'ticket': record['ticket'], 'producerId': producer_id,
                 'operation': plan['operation'], 'project': plan['project'], 'resources': producer['resources'],
                 'completedAt': stamp(), 'continuation': reference, 'journalSha256': identity(selected)}
        temporary = beneath(lease.coordinator.root, 'native-completions/' + record['ticket'] + '/' + producer_id + '/pending.json')
        write_json(temporary, value)
        sha = digest(temporary)
        path = temporary.with_name(sha + '.json')
        temporary.replace(path)
        producer['completion'] = {'path': path.relative_to(lease.coordinator.root).as_posix(), 'sha256': sha}
        lease.coordinator.save(record)
        lease.record = record
        return {'event': 'lifecycle-completed', 'ticket': record['ticket'], 'producerId': producer_id, 'sha256': sha}


def recover_completed(recovery, journal, producers, observations):
    from .access_recovery import VerifiedRecovery
    record = recovery._current()
    roots = [key for key, value in native._index(record)['producers'].items()
             if value['participantId'] is None and value.get('completion')]
    if len(roots) != 1:
        raise WorkError('NATIVE_LIFECYCLE_ROOT_COMPLETION_REQUIRED')
    completed = read(recovery.coordinator, record, roots[0])
    if completed['resources'] != record['resources'] or completed['operation'] != record['owner']['operation']:
        raise WorkError('NATIVE_LIFECYCLE_COMPLETION_SCOPE_CHANGED')
    if any(duty['status'] == 'pending' for duty in journal['restoration']['duties']):
        raise WorkError('NATIVE_LIFECYCLE_COMPLETION_RESTORATION_PENDING')
    assert_quiescent(recovery, journal, observations, completed['project'])
    return VerifiedRecovery(tuple(record['resources']), {
        'adapter': 'workflow-completed-lifecycle', 'operation': completed['operation'],
        'originalOutcome': 'interrupted', 'resolution': 'completion-acknowledged-before-interruption',
        'producerId': roots[0], 'producers': producers, 'originalRecordRevision': journal['recordRevision'],
        'nativeObservations': observations,
        'preservedResult': 'database, source, lifecycle state and seed left unchanged',
        'verification': 'no action replay and no new verification claim',
    })


def assert_quiescent(recovery, journal, observations, project):
    record = recovery._current()
    used = {resource for operation in journal['operations'] if operation['startAttempted']
            for resource in recovery.coordinator.resources(operation['admissions'])}
    if not observations:
        raise WorkError('NATIVE_RECOVERY_INSPECTION_UNCONFIRMED')
    for observation in observations:
        if len(observation['observation']['samples']) != 2:
            raise WorkError('NATIVE_RECOVERY_INSPECTION_UNCONFIRMED')
        for sample in observation['observation']['samples']:
            if recovery.coordinator.resources(sample['resources']) != record['resources']:
                raise WorkError('NATIVE_RECOVERY_INSPECTION_SCOPE_CHANGED')
            for base in sample['resources']:
                resource = recovery.coordinator.resources([base])[0]
                path = Path(base['path'])
                unused_service = (resource not in used and base['kind'] == 'file' and
                    path.parent == Path(project) / '.agent-1c' / 'infobases' and
                    re.fullmatch('vanessa-service-[a-f0-9]{32}', path.name) and
                    not base['directoryPresent'] and not base['databasePresent'])
                if base['sessionCount'] or (not unused_service and (not base['databasePresent'] or not base['exclusive'])):
                    raise WorkError('NATIVE_RECOVERY_DATABASE_STILL_IN_USE')
