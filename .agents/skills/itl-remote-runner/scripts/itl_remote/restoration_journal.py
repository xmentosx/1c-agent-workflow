"""Authority-indexed restoration duties, independent of native process exit."""
from __future__ import annotations

import copy
from pathlib import Path
import re
import time

from .common import WorkError, beneath, digest, identity, read_json, stamp, write_json
from . import native_journal as native


def _validate(value):
    fields = {'schemaVersion', 'journalId', 'ticket', 'id', 'createdAt', 'updatedAt',
              'hostName', 'ownerPid', 'operation', 'project', 'resources', 'resourceIds',
              'kind', 'snapshotPath', 'snapshotSha256', 'policy', 'status', 'helperInputs'}
    if not isinstance(value, dict):
        raise WorkError('RESTORATION_JOURNAL_RECORD_INVALID')
    if value.get('kind') == 'config-dump-info':
        fields |= {'destination', 'existed'}
    elif value.get('kind') == 'infobase-snapshot':
        fields |= {'infoBase', 'restoreOperation', 'recoveryContext'}
    else:
        raise WorkError('RESTORATION_JOURNAL_KIND_INVALID')
    if set(value) != fields or value['schemaVersion'] != 1:
        raise WorkError('RESTORATION_JOURNAL_RECORD_INVALID')
    for name in ('journalId', 'ticket', 'id'):
        native._identifier(value[name])
    if any(not isinstance(value[name], str) for name in fields - {
            'schemaVersion', 'ownerPid', 'resources', 'resourceIds', 'existed', 'infoBase', 'helperInputs', 'recoveryContext'}):
        raise WorkError('RESTORATION_JOURNAL_TEXT_INVALID')
    if (type(value['ownerPid']) is not int or value['ownerPid'] <= 0 or
            value['policy'] not in ('always', 'on-failure') or
            value['status'] not in ('pending', 'restored', 'committed') or
            (value['status'] == 'committed' and value['policy'] != 'on-failure')):
        raise WorkError('RESTORATION_JOURNAL_INPUT_INVALID')
    if value['kind'] == 'config-dump-info':
        if (type(value['existed']) is not bool or not Path(value['destination']).is_absolute() or
                Path(value['destination']).name.casefold() != 'configdumpinfo.xml'):
            raise WorkError('RESTORATION_JOURNAL_INPUT_INVALID')
    else:
        base = value['infoBase']
        if (not isinstance(base, dict) or set(base) != {'kind', 'path'} or
                base['kind'] not in ('file', 'server') or not isinstance(base['path'], str) or not base['path'] or
                (value['restoreOperation'] and not re.fullmatch('[a-f0-9]{32}/[a-f0-9]{32}', value['restoreOperation']))):
            raise WorkError('RESTORATION_JOURNAL_INPUT_INVALID')
        context = value['recoveryContext']
        if context is not None and (not isinstance(context, dict) or set(context) != {'path', 'sha256'} or
                any(not isinstance(context[name], str) or not context[name] for name in ('path', 'sha256'))):
            raise WorkError('RESTORATION_JOURNAL_CONTEXT_INVALID')
    if not isinstance(value['resources'], list) or not value['resources'] or not isinstance(value['resourceIds'], list):
        raise WorkError('RESTORATION_JOURNAL_RESOURCES_INVALID')
    if not isinstance(value['helperInputs'], list) or not value['helperInputs']:
        raise WorkError('RESTORATION_JOURNAL_HELPERS_REQUIRED')
    for helper in value['helperInputs']:
        if (not isinstance(helper, dict) or set(helper) != {'path', 'sha256'} or
                not isinstance(helper['path'], str) or not helper['path'] or
                not isinstance(helper['sha256'], str) or not re.fullmatch('[a-f0-9]{64}', helper['sha256'])):
            raise WorkError('RESTORATION_JOURNAL_HELPER_INVALID')
    for base in value['resources']:
        if (not isinstance(base, dict) or set(base) != {'kind', 'path'} or
                base['kind'] not in ('file', 'server') or not isinstance(base['path'], str) or not base['path']):
            raise WorkError('RESTORATION_JOURNAL_RESOURCES_INVALID')
    if value['kind'] == 'infobase-snapshot' or value['existed']:
        if not Path(value['snapshotPath']).is_absolute() or not re.fullmatch('[a-f0-9]{64}', value['snapshotSha256']):
            raise WorkError('RESTORATION_JOURNAL_SNAPSHOT_INVALID')
    elif value['snapshotPath'] or value['snapshotSha256']:
        raise WorkError('RESTORATION_JOURNAL_SNAPSHOT_INVALID')


def _snapshot(coordinator, value):
    path = Path(value['snapshotPath'])
    if value['kind'] == 'config-dump-info':
        root = coordinator.root / 'restoration-snapshots'
        expected = root / value['ticket'] / value['journalId'] / (value['id'] + '.xml')
        if path != expected:
            raise WorkError('RESTORATION_JOURNAL_SNAPSHOT_SCOPE_CHANGED')
        components = (root, expected.parent.parent, expected.parent, path)
    else:
        # DT can be large: pin the caller's existing owned snapshot rather than
        # make another database-sized copy for the journal.
        root = Path(value['project']) / '.agent-1c' / 'snapshots'
        if not root.is_absolute() or path.parent != root or path.suffix.casefold() != '.dt':
            raise WorkError('RESTORATION_JOURNAL_SNAPSHOT_SCOPE_CHANGED')
        components = (root.parent, root, path)
    for component in components:
        if component.is_symlink() or getattr(component, 'is_junction', lambda: False)():
            raise WorkError('RESTORATION_JOURNAL_SNAPSHOT_REDIRECTED')
    if not path.is_file() or (value['kind'] == 'infobase-snapshot' and path.stat().st_size <= 0) or digest(path) != value['snapshotSha256']:
        raise WorkError('RESTORATION_JOURNAL_SNAPSHOT_CHANGED')
    if value['kind'] == 'infobase-snapshot' and value['recoveryContext'] is not None:
        from . import restoration_context
        restoration_context.read(coordinator, value)


def _database_restore(coordinator, record, producer, value):
    entry = producer['records'].get(value['restoreOperation'])
    if entry is None:
        raise WorkError('RESTORATION_JOURNAL_NATIVE_RESTORE_UNPROVEN')
    operation = native._read_operation(coordinator, record['ticket'], value['restoreOperation'], entry)
    if (operation['purpose'] != 'designer-restore-snapshot-' + value['id'] or
            coordinator.resources(operation['admissions']) != coordinator.resources([value['infoBase']]) or
            not operation['startAttempted'] or not operation['launcherExited'] or not operation['quiescenceConfirmed']):
        raise WorkError('RESTORATION_JOURNAL_NATIVE_RESTORE_UNPROVEN')


def _restored(value):
    path = Path(value['destination'])
    if path.is_symlink() or getattr(path, 'is_junction', lambda: False)():
        raise WorkError('RESTORATION_JOURNAL_DESTINATION_REDIRECTED')
    if value['existed']:
        if not path.is_file() or digest(path) != value['snapshotSha256']:
            raise WorkError('RESTORATION_JOURNAL_RESTORATION_UNCONFIRMED')
    elif path.exists():
        raise WorkError('RESTORATION_JOURNAL_RESTORATION_UNCONFIRMED')


def _entries(producer):
    if producer.get('restorationProtocol') != 1 or not isinstance(producer.get('restorations'), dict):
        raise WorkError('RESTORATION_JOURNAL_PROTOCOL_REQUIRED')
    return producer['restorations']


def read(coordinator, ticket, key, entry):
    ids = key.split('/')
    if len(ids) != 2:
        raise WorkError('RESTORATION_JOURNAL_INDEX_INVALID')
    for identifier in ids:
        native._identifier(identifier)
    if not isinstance(entry, dict) or set(entry) != {'path', 'sha256'} or not isinstance(entry['path'], str):
        raise WorkError('RESTORATION_JOURNAL_INDEX_INVALID')
    relative = Path(entry['path'])
    if (relative.is_absolute() or relative.parts[:-1] != ('restoration-duties', ticket, *ids) or
            not re.fullmatch('[a-f0-9]{64}\\.json', relative.name)):
        raise WorkError('RESTORATION_JOURNAL_INDEX_INVALID')
    path = beneath(coordinator.root, relative.as_posix())
    if not path.is_file() or digest(path) != entry['sha256']:
        raise WorkError('RESTORATION_JOURNAL_RECORD_CHANGED')
    value = read_json(path)
    _validate(value)
    if (value['ticket'] != ticket or value['journalId'] != ids[0] or value['id'] != ids[1] or
            identity(value) != path.stem):
        raise WorkError('RESTORATION_JOURNAL_BINDING_CHANGED')
    return value


def publish(lease, producer_id, payload):
    _validate(payload)
    lease.validate()
    with lease.coordinator.mutex(time.monotonic() + 30, lease.cancelled):
        record = native._current(lease)
        producers = native._index(record)['producers']
        producer = producers.get(producer_id)
        from .native_completion import assert_writable
        assert_writable(record, producer_id)
        if (not producer or producer.get('protocol') != 1 or
                producer['generation'] != identity(record['token']) or
                producer['participantId'] != lease.participant_id or
                payload['ticket'] != record['ticket'] or payload['ownerPid'] != producer['ownerPid'] or
                payload['hostName'].casefold() != producer['hostName'].casefold()):
            raise WorkError('RESTORATION_JOURNAL_PRODUCER_MISMATCH')
        entries = _entries(producer)
        resources = lease.coordinator.resources(payload['resources'])
        if (not set(resources) <= set(producer['resources']) or
                (payload['kind'] == 'infobase-snapshot' and not set(lease.coordinator.resources([payload['infoBase']])) <= set(resources))):
            raise WorkError('RESTORATION_JOURNAL_TARGET_NOT_RESERVED')
        value = copy.deepcopy(payload)
        value['resourceIds'] = resources
        key = value['journalId'] + '/' + value['id']
        native.assert_journal_owner(producers, producer_id, value['journalId'])
        previous = entries.get(key)
        if previous:
            before = read(lease.coordinator, record['ticket'], key, previous)
            if any(before[name] != value[name] for name in value if name not in ('updatedAt', 'status', 'restoreOperation')):
                raise WorkError('RESTORATION_JOURNAL_IMMUTABLE_INPUT_CHANGED')
            if before['status'] != 'pending' and (value['status'] != before['status'] or
                    value.get('restoreOperation') != before.get('restoreOperation')):
                raise WorkError('RESTORATION_JOURNAL_COMPLETED_DUTY_REUSED')
        elif value['status'] != 'pending':
            raise WorkError('RESTORATION_JOURNAL_INTENT_REQUIRED')
        if value['kind'] == 'infobase-snapshot' or value['existed']:
            _snapshot(lease.coordinator, value)
        if value['kind'] == 'infobase-snapshot':
            if value['restoreOperation'] or value['status'] == 'restored':
                _database_restore(lease.coordinator, record, producer, value)
        elif value['status'] == 'restored':
            _restored(value)
        relative = Path('restoration-duties') / record['ticket'] / value['journalId'] / value['id'] / (identity(value) + '.json')
        destination = beneath(lease.coordinator.root, relative.as_posix())
        if destination.exists():
            if read_json(destination) != value:
                raise WorkError('RESTORATION_JOURNAL_IMMUTABLE_SNAPSHOT_CHANGED')
        else:
            write_json(destination, value)
        entry = {'path': relative.as_posix(), 'sha256': digest(destination)}
        entries[key] = entry
        lease.coordinator.save(record)
        lease.record = record
        return {'event': 'restoration-duty-recorded', 'ticket': value['ticket'], 'journalId': value['journalId'],
                'id': value['id'], 'path': str(destination), 'sha256': entry['sha256']}


def commit_recovered_source_cursor(recovery, key, *, project, destination):
    """Commit one on-failure cursor duty after a bound native load succeeded."""
    with recovery.coordinator.mutex(time.monotonic() + 30, recovery.cancelled):
        record = recovery._current()
        matches = []
        for producer_id, producer in native._index(record)['producers'].items():
            entry = _entries(producer).get(key)
            if entry is not None:
                matches.append((producer_id, producer, entry))
        if len(matches) != 1:
            raise WorkError('SOURCE_SYNC_RECOVERY_CURSOR_DUTY_AMBIGUOUS')
        producer_id, producer, entry = matches[0]
        value = read(recovery.coordinator, record['ticket'], key, entry)
        expected = Path(destination)
        if (value['kind'] != 'config-dump-info' or value['policy'] != 'on-failure' or
                value['project'] != project or Path(value['destination']) != expected or
                value['status'] not in ('pending', 'committed')):
            raise WorkError('SOURCE_SYNC_RECOVERY_CURSOR_DUTY_CHANGED')
        if value['status'] == 'committed':
            return value
        if not expected.is_file() or expected.is_symlink() or getattr(expected, 'is_junction', lambda: False)():
            raise WorkError('SOURCE_SYNC_RECOVERY_CURSOR_RESULT_MISSING')
        updated = copy.deepcopy(value)
        updated.update(status='committed', updatedAt=stamp())
        _validate(updated)
        relative = Path('restoration-duties') / record['ticket'] / updated['journalId'] / updated['id'] / (identity(updated) + '.json')
        target = beneath(recovery.coordinator.root, relative.as_posix())
        if target.exists():
            if read_json(target) != updated:
                raise WorkError('RESTORATION_JOURNAL_IMMUTABLE_SNAPSHOT_CHANGED')
        else:
            write_json(target, updated)
        producer['restorations'][key] = {'path': relative.as_posix(), 'sha256': digest(target)}
        recovery.coordinator.save(record)
        recovery.record = record
        return updated


def inspect(coordinator, record):
    duties, seen = [], set()
    coverage = True
    producers = native._index(record)['producers']
    for producer_id, producer in producers.items():
        if 'restorationProtocol' not in producer:
            coverage = False  # Historical absence is not evidence of no duty.
            continue
        for key, entry in _entries(producer).items():
            if key in seen:
                raise WorkError('RESTORATION_JOURNAL_DUPLICATE_DUTY')
            seen.add(key)
            value = read(coordinator, record['ticket'], key, entry)
            native.assert_journal_owner(producers, producer_id, value['journalId'])
            resources = coordinator.resources(value['resources'])
            if (resources != value['resourceIds'] or not set(resources) <= set(producer['resources']) or
                    not set(resources) <= set(record['resources'])):
                raise WorkError('RESTORATION_JOURNAL_RESOURCE_BINDING_CHANGED')
            duties.append(value)
    # These are explicit snapshot duties, not a declaration that the complete
    # operation has no other repository or lifecycle-state restoration duty.
    return {'protocol': 'available' if coverage else 'legacy-unknown', 'duties': duties,
            'trackedKinds': ['config-dump-info', 'infobase-snapshot'], 'requiresOperationRestorationContract': True,
            'requiresLiveVerification': True}


def release_errors(coordinator, record, producer_id):
    producer = native._index(record)['producers'][producer_id]
    if 'restorationProtocol' not in producer:
        return []  # Existing native-only releases keep their original contract.
    return ['restoration-duty-unconfirmed'] if any(
        read(coordinator, record['ticket'], key, entry)['status'] == 'pending'
        for key, entry in _entries(producer).items()) else []
