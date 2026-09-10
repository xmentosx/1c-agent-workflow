"""Immutable admitted resource plans for fresh lifecycle helper processes."""
from pathlib import Path
import copy
import re
import time

from .common import WorkError, beneath, digest, identity, read_json, write_json
from . import native_journal as native


def validate(plan):
    fields = {'schemaVersion', 'operation', 'project', 'target', 'bases',
              'serviceGeneration', 'serviceReserveGeneration', 'helperInputs'}
    if (not isinstance(plan, dict) or set(plan) != fields or plan['schemaVersion'] != 1 or
            not isinstance(plan['operation'], str) or not plan['operation'] or
            not isinstance(plan['project'], str) or not Path(plan['project']).is_absolute() or
            not isinstance(plan['bases'], list) or not plan['bases'] or
            not isinstance(plan['helperInputs'], list) or not plan['helperInputs']):
        raise WorkError('NATIVE_CONTINUATION_PLAN_INVALID')
    for base in [plan['target'], *plan['bases']]:
        if (not isinstance(base, dict) or set(base) != {'kind', 'path'} or
                base['kind'] not in ('file', 'server') or not isinstance(base['path'], str) or not base['path']):
            raise WorkError('NATIVE_CONTINUATION_RESOURCE_INVALID')
    for name in ('serviceGeneration', 'serviceReserveGeneration'):
        if not isinstance(plan[name], str) or (plan[name] and not re.fullmatch('[a-f0-9]{32}', plan[name])):
            raise WorkError('NATIVE_CONTINUATION_GENERATION_INVALID')
    for helper in plan['helperInputs']:
        if (not isinstance(helper, dict) or set(helper) != {'path', 'sha256'} or
                not isinstance(helper['path'], str) or not Path(helper['path']).is_absolute() or
                not isinstance(helper['sha256'], str) or not re.fullmatch('[a-f0-9]{64}', helper['sha256'])):
            raise WorkError('NATIVE_CONTINUATION_HELPER_INVALID')


def read(coordinator, record, reference):
    if (not isinstance(reference, dict) or set(reference) != {'ticket', 'producerId', 'sha256'} or
            reference['ticket'] != record['ticket']):
        raise WorkError('NATIVE_CONTINUATION_REFERENCE_INVALID')
    producer_id = native._identifier(reference['producerId'])
    producer = native._index(record)['producers'].get(producer_id)
    entry = producer.get('continuation') if producer else None
    if (not isinstance(entry, dict) or set(entry) != {'path', 'sha256'} or
            not isinstance(entry.get('sha256'), str) or not re.fullmatch('[a-f0-9]{64}', entry['sha256']) or
            reference['sha256'] != entry['sha256']):
        raise WorkError('NATIVE_CONTINUATION_REFERENCE_CHANGED')
    expected = Path('native-continuations') / record['ticket'] / producer_id / (entry['sha256'] + '.json')
    if entry['path'] != expected.as_posix():
        raise WorkError('NATIVE_CONTINUATION_REFERENCE_CHANGED')
    path = beneath(coordinator.root, entry['path'])
    if not path.is_file() or digest(path) != entry['sha256']:
        raise WorkError('NATIVE_CONTINUATION_RECORD_CHANGED')
    value = read_json(path)
    if (not isinstance(value, dict) or set(value) != {'schemaVersion', 'ticket', 'producerId', 'plan', 'parent'} or
            value['schemaVersion'] != 1 or value['ticket'] != record['ticket'] or value['producerId'] != producer_id):
        raise WorkError('NATIVE_CONTINUATION_RECORD_CHANGED')
    validate(value['plan'])
    resources = coordinator.resources(value['plan']['bases'])
    if resources != producer['resources'] or not set(resources) <= set(record['resources']):
        raise WorkError('NATIVE_CONTINUATION_RESOURCE_BINDING_CHANGED')
    return value


def publish(lease, producer_id, plan, parent=None):
    validate(plan)
    lease.validate()
    with lease.coordinator.mutex(time.monotonic() + 30, lease.cancelled):
        record = native._current(lease)
        from .native_completion import assert_writable
        assert_writable(record, producer_id)
        producer = native._index(record)['producers'].get(producer_id)
        resources = lease.coordinator.resources(plan['bases'])
        if (not producer or producer['participantId'] != lease.participant_id or
                producer['generation'] != identity(record['token']) or resources != producer['resources'] or
                plan['operation'] != lease.owner.get('operation') or
                Path(plan['project']) != Path(lease.owner.get('project', '')) or
                not set(lease.coordinator.resources([plan['target']])) <= set(resources)):
            raise WorkError('NATIVE_CONTINUATION_OWNER_MISMATCH')
        for name in ('serviceGeneration', 'serviceReserveGeneration'):
            if plan[name]:
                service = {'kind': 'file', 'path': str(Path(plan['project']) / '.agent-1c' / 'infobases' / ('vanessa-service-' + plan[name]))}
                if not set(lease.coordinator.resources([service])) <= set(resources):
                    raise WorkError('NATIVE_CONTINUATION_SERVICE_NOT_RESERVED')
        from .native_recovery_helpers import resolve
        resolve(lease.coordinator, plan['helperInputs'])
        if parent is not None:
            if not isinstance(parent, dict) or not lease.inherited or parent.get('producerId') == producer_id:
                raise WorkError('NATIVE_CONTINUATION_PARENT_INVALID')
            previous = read(lease.coordinator, record, parent)['plan']
            if native._index(record)['producers'][parent['producerId']]['generation'] != producer['generation']:
                from .native_reset import assert_recovery_handoff
                assert_recovery_handoff(lease, record, parent)
            if (previous['operation'] != plan['operation'] or Path(previous['project']) != Path(plan['project']) or
                    lease.coordinator.resources(previous['bases']) != resources or
                    lease.coordinator.resources([previous['target']]) != lease.coordinator.resources([plan['target']]) or
                    previous['serviceReserveGeneration'] != plan['serviceReserveGeneration'] or
                    plan['serviceGeneration'] not in (previous['serviceGeneration'], previous['serviceReserveGeneration'])):
                raise WorkError('NATIVE_CONTINUATION_PLAN_CHANGED')
        if producer.get('continuation') is not None:
            raise WorkError('NATIVE_CONTINUATION_ALREADY_PUBLISHED')
        value = {'schemaVersion': 1, 'ticket': record['ticket'], 'producerId': producer_id,
                 'plan': copy.deepcopy(plan), 'parent': parent}
        # The content digest is calculated from the same canonical writer bytes,
        # not from locale-dependent PowerShell serialization.
        temporary = beneath(lease.coordinator.root, ('native-continuations/' + record['ticket'] + '/' + producer_id + '/pending.json'))
        write_json(temporary, value)
        sha = digest(temporary)
        path = temporary.with_name(sha + '.json')
        temporary.replace(path)
        producer['continuation'] = {'path': path.relative_to(lease.coordinator.root).as_posix(), 'sha256': sha}
        lease.coordinator.save(record)
        lease.record = record
        return {'event': 'continuation-plan-recorded', 'reference': {'ticket': record['ticket'], 'producerId': producer_id, 'sha256': sha},
                'plan': copy.deepcopy(plan)}
