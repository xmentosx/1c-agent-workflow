"""Acknowledge source-group phases without replaying their database effects."""
from pathlib import Path
import copy
import hashlib
import re
import subprocess
import time

from .common import WorkError, beneath, digest, identity, read_json, stamp, write_json
from . import native_journal as native

STEPS = ('load', 'normalize', 'runtime', 'cursor', 'state')


def validate(value):
    fields = {'schemaVersion', 'groupId', 'stepId', 'step', 'status', 'project', 'member',
              'members', 'sourceFingerprint', 'sourceCommit', 'exportPath', 'result'}
    modern = fields | {'contentKind', 'extensionName'}
    if (not isinstance(value, dict) or
            not (set(value) == fields and value.get('schemaVersion') == 1 or
                 set(value) == modern and value.get('schemaVersion') == 2)):
        raise WorkError('SOURCE_SYNC_PHASE_INVALID')
    if set(value) == modern and (value['contentKind'] not in ('configuration', 'extension') or
            not isinstance(value['extensionName'], str) or
            (value['contentKind'] == 'extension') != bool(value['extensionName'])):
        raise WorkError('SOURCE_SYNC_PHASE_SCOPE_INVALID')
    for key in ('groupId', 'stepId'):
        native._identifier(value[key])
    if (value['step'] not in STEPS or value['status'] not in ('running', 'completed') or not isinstance(value['project'], str) or
            not Path(value['project']).is_absolute() or not isinstance(value['member'], str) or
            not value['member'] or not isinstance(value['sourceFingerprint'], str) or
            not re.fullmatch(r'v2\|git-tree-sha256\|[a-f0-9]{64}', value['sourceFingerprint']) or
            not isinstance(value['sourceCommit'], str) or not re.fullmatch('[a-f0-9]{40,64}', value['sourceCommit']) or
            not isinstance(value['exportPath'], str) or not value['exportPath'] or
            Path(value['exportPath']).is_absolute() or '..' in Path(value['exportPath']).parts or
            not isinstance(value['result'], dict) or (value['status'] == 'running' and value['result']) or
            not isinstance(value['members'], list) or not value['members']):
        raise WorkError('SOURCE_SYNC_PHASE_SCOPE_INVALID')
    names = set()
    for member in value['members']:
        if (not isinstance(member, dict) or set(member) != {'name', 'project', 'target'} or
                not isinstance(member['name'], str) or not member['name'] or member['name'].casefold() in names or
                not isinstance(member['project'], str) or not Path(member['project']).is_absolute() or
                not isinstance(member['target'], dict) or set(member['target']) != {'kind', 'path'} or
                member['target']['kind'] not in ('file', 'server') or
                not isinstance(member['target']['path'], str) or not member['target']['path']):
            raise WorkError('SOURCE_SYNC_PHASE_MEMBER_INVALID')
        names.add(member['name'].casefold())
    if value['member'].casefold() not in names:
        raise WorkError('SOURCE_SYNC_PHASE_MEMBER_INVALID')


def snapshot(record):
    # Native content-index entries are immutable references. Phase receipts must
    # not include themselves or a later receipt would recursively grow the log.
    return {key: {field: copy.deepcopy(producer[field]) for field in
                  ('generation', 'participantId', 'resources', 'records', 'restorations')}
            for key, producer in native._index(record)['producers'].items()}


def publish(lease, producer_id, payload):
    validate(payload)
    lease.validate()
    with lease.coordinator.mutex(time.monotonic() + 30, lease.cancelled):
        record = native._current(lease)
        producers = native._index(record)['producers']
        producer = producers.get(producer_id)
        if (not producer or producer['participantId'] != lease.participant_id or
                producer['generation'] != identity(record['token']) or
                lease.owner.get('operation') != 'sync-dev-branches' or
                Path(payload['project']) != Path(lease.owner.get('project', '')) or
                not set(lease.coordinator.resources([m['target'] for m in payload['members']])) <= set(producer['resources'])):
            raise WorkError('SOURCE_SYNC_PHASE_OWNER_CHANGED')
        from .native_completion import assert_writable
        assert_writable(record, producer_id)
        # Successful high-level return is acknowledged only after its native
        # children and restoration duties have been accounted for.
        inspected = native.inspect(lease.coordinator, record)
        if any(op['startAttempted'] and not op['quiescenceConfirmed'] for op in inspected['operations']):
            raise WorkError('SOURCE_SYNC_PHASE_NATIVE_WORK_PENDING')
        if any(duty['status'] == 'pending' for duty in inspected['restoration']['duties']):
            raise WorkError('SOURCE_SYNC_PHASE_RESTORATION_PENDING')
        entries = producer.setdefault('sourceSyncPhases', {})
        intent = None
        sequence = len(entries) + 1
        if payload['stepId'] in entries:
            previous = read(lease.coordinator, record, producer_id, payload['stepId'])
            if previous['phase'] == payload and previous['nativeSnapshot'] == snapshot(record):
                return reference(record, producer_id, payload['stepId'], entries[payload['stepId']])
            stable = {key: value for key, value in payload.items() if key not in ('status', 'result')}
            old_stable = {key: value for key, value in previous['phase'].items() if key not in ('status', 'result')}
            if previous['phase']['status'] != 'running' or payload['status'] != 'completed' or stable != old_stable:
                raise WorkError('SOURCE_SYNC_PHASE_ALREADY_ACKNOWLEDGED')
            intent = copy.deepcopy(entries[payload['stepId']])
            sequence = previous['sequence']
        elif payload['status'] != 'running':
            raise WorkError('SOURCE_SYNC_PHASE_INTENT_REQUIRED')
        value = {'schemaVersion': 1, 'ticket': record['ticket'], 'producerId': producer_id,
                 'sequence': sequence, 'acknowledgedAt': stamp(), 'intent': intent,
                 'phase': copy.deepcopy(payload), 'nativeSnapshot': snapshot(record)}
        directory = beneath(lease.coordinator.root, 'source-sync-phases/' + record['ticket'] + '/' + producer_id)
        temporary = directory / (payload['stepId'] + '.pending.json')
        write_json(temporary, value)
        sha = digest(temporary)
        path = temporary.with_name(sha + '.json')
        temporary.replace(path)
        entry = {'path': path.relative_to(lease.coordinator.root).as_posix(), 'sha256': sha}
        entries[payload['stepId']] = entry
        lease.coordinator.save(record)
        lease.record = record
        return reference(record, producer_id, payload['stepId'], entry)


def reference(record, producer_id, step_id, entry):
    return {'event': 'source-sync-phase-recorded', 'ticket': record['ticket'],
            'producerId': producer_id, 'stepId': step_id, 'sha256': entry['sha256']}


def read(coordinator, record, producer_id, step_id, *, entry=None, intent_only=False):
    native._identifier(producer_id)
    native._identifier(step_id)
    producer = native._index(record)['producers'].get(producer_id, {})
    if entry is None:
        entry = producer.get('sourceSyncPhases', {}).get(step_id)
    if (not isinstance(entry, dict) or set(entry) != {'path', 'sha256'} or
            not isinstance(entry['sha256'], str) or not re.fullmatch('[a-f0-9]{64}', entry['sha256'])):
        raise WorkError('SOURCE_SYNC_PHASE_REFERENCE_INVALID')
    expected = 'source-sync-phases/' + record['ticket'] + '/' + producer_id + '/' + entry['sha256'] + '.json'
    if entry['path'] != expected:
        raise WorkError('SOURCE_SYNC_PHASE_REFERENCE_CHANGED')
    path = beneath(coordinator.root, expected)
    if not path.is_file() or digest(path) != entry['sha256']:
        raise WorkError('SOURCE_SYNC_PHASE_ARTIFACT_CHANGED')
    value = read_json(path)
    if (not isinstance(value, dict) or set(value) != {'schemaVersion', 'ticket', 'producerId', 'sequence',
            'acknowledgedAt', 'phase', 'nativeSnapshot', 'intent'} or value['schemaVersion'] != 1 or
            value['ticket'] != record['ticket'] or value['producerId'] != producer_id or
            type(value['sequence']) is not int or value['sequence'] < 1 or
            not isinstance(value['nativeSnapshot'], dict)):
        raise WorkError('SOURCE_SYNC_PHASE_ARTIFACT_INVALID')
    validate(value['phase'])
    if value['phase']['stepId'] != step_id:
        raise WorkError('SOURCE_SYNC_PHASE_BINDING_CHANGED')
    if intent_only and value['phase']['status'] != 'running':
        raise WorkError('SOURCE_SYNC_PHASE_INTENT_INVALID')
    if value['phase']['status'] == 'running':
        if value['intent'] is not None:
            raise WorkError('SOURCE_SYNC_PHASE_INTENT_INVALID')
    else:
        # The intent must be a distinct earlier artifact, never an arbitrary
        # recursive chain of completion records.
        intent_entry = value['intent']
        if not isinstance(intent_entry, dict) or intent_entry == entry:
            raise WorkError('SOURCE_SYNC_PHASE_INTENT_INVALID')
        intent_value = read(coordinator, record, producer_id, step_id, entry=intent_entry, intent_only=True)
        stable = lambda item: {key: val for key, val in item['phase'].items() if key not in ('status', 'result')}
        if intent_value['sequence'] != value['sequence'] or stable(intent_value) != stable(value):
            raise WorkError('SOURCE_SYNC_PHASE_INTENT_CHANGED')
    return value


def inspect(coordinator, record):
    return [read(coordinator, record, producer_id, step_id)
            for producer_id, producer in native._index(record)['producers'].items()
            for step_id in producer.get('sourceSyncPhases', {})]


def observe(lease, ticket, expected):
    """Read an earlier intent/receipt while owning the same admitted scope."""
    native._identifier(ticket)
    validate(expected)
    lease.validate()
    if (expected['status'] != 'running' or lease.owner.get('operation') != 'sync-dev-branches' or
            Path(expected['project']) != Path(lease.owner.get('project', '')) or
            not set(lease.coordinator.resources([m['target'] for m in expected['members']])) <= set(lease.record['resources'])):
        raise WorkError('SOURCE_SYNC_PHASE_READER_SCOPE_CHANGED')
    record = read_json(beneath(lease.coordinator.root, 'tickets/' + ticket + '.json'))
    if (record.get('ticket') != ticket or record.get('owner', {}).get('operation') != 'sync-dev-branches' or
            Path(record['owner'].get('project', '')) != Path(expected['project']) or
            (ticket != lease.record['ticket'] and record['status'] != 'released')):
        raise WorkError('SOURCE_SYNC_PHASE_PREVIOUS_OWNER_UNRELEASED')
    phases = inspect(lease.coordinator, record)
    matches = [item for item in phases if item['phase']['stepId'] == expected['stepId']]
    stable = lambda item: {key: value for key, value in item.items() if key not in ('status', 'result')}
    if len(matches) > 1:
        raise WorkError('SOURCE_SYNC_PHASE_AMBIGUOUS')
    response = {'event': 'source-sync-phase-observed', 'ticket': ticket, 'stepId': expected['stepId'],
                'completed': False, 'canStart': False, 'canResumeLocalSteps': record['status'] == 'released', 'result': None}
    if matches:
        item = matches[0]
        if stable(item['phase']) != stable(expected):
            raise WorkError('SOURCE_SYNC_PHASE_READER_SCOPE_CHANGED')
        response['completed'] = item['phase']['status'] == 'completed'
        response['canStart'] = not response['completed'] and item['nativeSnapshot'] == snapshot(record)
        response['result'] = item['phase']['result'] if response['completed'] else None
    else:
        # The producer requires an acknowledged intent before starting a step.
        # An absent intent is restartable only when no unacknowledged native
        # work exists anywhere in the previous admitted scope.
        selected = [item for item in phases if item['phase']['groupId'] == expected['groupId'] and
                    item['phase']['members'] == expected['members'] and
                    item['phase']['sourceFingerprint'] == expected['sourceFingerprint']]
        if phases and len(selected) != len(phases):
            raise WorkError('SOURCE_SYNC_PHASE_READER_SCOPE_CHANGED')
        if any(item['nativeSnapshot'] == snapshot(record) for item in selected):
            response['canStart'] = True
        elif not phases:
            observed = native.inspect(lease.coordinator, record)
            response['canStart'] = (not any(op['startAttempted'] for op in observed['operations']) and
                                    not any(d['status'] == 'pending' for d in observed['restoration']['duties']))
    return response


def _publish_recovered_completion(recovery, intent, result):
    """Write the phase receipt which the crashed producer could not publish."""
    with recovery.coordinator.mutex(time.monotonic() + 30, recovery.cancelled):
        record = recovery._current()
        producer_id = intent['producerId']
        producer = native._index(record)['producers'].get(producer_id)
        entry = producer.get('sourceSyncPhases', {}).get(intent['phase']['stepId']) if producer else None
        current = read(recovery.coordinator, record, producer_id, intent['phase']['stepId'], entry=entry)
        if current != intent or current['phase']['status'] != 'running':
            raise WorkError('SOURCE_SYNC_RECOVERY_PHASE_CHANGED')
        phase = copy.deepcopy(current['phase'])
        phase.update(status='completed', result=copy.deepcopy(result))
        value = {'schemaVersion': 1, 'ticket': record['ticket'], 'producerId': producer_id,
                 'sequence': current['sequence'], 'acknowledgedAt': stamp(), 'intent': copy.deepcopy(entry),
                 'phase': phase, 'nativeSnapshot': snapshot(record)}
        directory = beneath(recovery.coordinator.root, 'source-sync-phases/' + record['ticket'] + '/' + producer_id)
        temporary = directory / (phase['stepId'] + '.recovery.pending.json')
        write_json(temporary, value)
        sha = digest(temporary)
        path = temporary.with_name(sha + '.json')
        if path.exists():
            if read_json(path) != value:
                raise WorkError('SOURCE_SYNC_PHASE_ARTIFACT_CHANGED')
            temporary.unlink()
        else:
            temporary.replace(path)
        producer['sourceSyncPhases'][phase['stepId']] = {
            'path': path.relative_to(recovery.coordinator.root).as_posix(), 'sha256': sha}
        recovery.coordinator.save(record)
        recovery.record = record
        return value


def _verify_source_commit(phase, effect):
    project = Path(phase['project'])
    if not project.is_dir() or project.is_symlink() or getattr(project, 'is_junction', lambda: False)():
        raise WorkError('SOURCE_SYNC_RECOVERY_SOURCE_PROJECT_CHANGED')
    try:
        tree = subprocess.run(['git', '-C', str(project), 'rev-parse',
                               phase['sourceCommit'] + ':' + phase['exportPath']],
                              check=True, capture_output=True, timeout=30).stdout.decode('ascii').strip()
        listing = subprocess.run(['git', '-c', 'core.quotepath=false', '-C', str(project), 'ls-tree', '-r', '-z',
                                  phase['sourceCommit'] + ':' + phase['exportPath']],
                                 check=True, capture_output=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError, UnicodeError) as error:
        raise WorkError('SOURCE_SYNC_RECOVERY_SOURCE_COMMIT_UNAVAILABLE') from error
    entries = []
    for entry in listing.split(b'\0'):
        if not entry:
            continue
        separator = entry.find(b'\t')
        if separator < 0:
            raise WorkError('SOURCE_SYNC_RECOVERY_SOURCE_TREE_INVALID')
        try:
            leaf = entry[separator + 1:].decode('utf-8').replace('\\', '/').rsplit('/', 1)[-1]
        except UnicodeError as error:
            raise WorkError('SOURCE_SYNC_RECOVERY_SOURCE_TREE_INVALID') from error
        if leaf.casefold() != 'configdumpinfo.xml':
            entries.append(entry)
    fingerprint = 'v2|git-tree-sha256|' + hashlib.sha256(b'\0'.join(entries)).hexdigest()
    if tree != effect['sourceTreeObjectId'] or fingerprint != phase['sourceFingerprint']:
        raise WorkError('SOURCE_SYNC_RECOVERY_SOURCE_IDENTITY_CHANGED')
    return {'treeObjectId': tree, 'fingerprint': fingerprint, 'fileCount': len(entries)}


def _reconcile_completed_load(recovery, journal):
    """Accept only a terminal, source-bound Designer success after one saved intent."""
    intents = [item for item in journal.get('sourceSyncPhases', []) if item['phase']['status'] == 'running']
    if len(intents) != 1 or intents[0]['phase']['step'] != 'load':
        raise WorkError('SOURCE_SYNC_RECOVERY_UNACKNOWLEDGED_NATIVE_WORK')
    intent = intents[0]
    phase, producer_id = intent['phase'], intent['producerId']
    if phase['schemaVersion'] != 2:
        raise WorkError('SOURCE_SYNC_RECOVERY_UNACKNOWLEDGED_NATIVE_WORK: source content contract unavailable')
    record = recovery._current()
    producer = native._index(record)['producers'].get(producer_id)
    before = intent['nativeSnapshot'].get(producer_id)
    if not producer or not before:
        raise WorkError('SOURCE_SYNC_RECOVERY_PHASE_OWNER_CHANGED')
    if set(native._index(record)['producers']) != set(intent['nativeSnapshot']):
        raise WorkError('SOURCE_SYNC_RECOVERY_CONCURRENT_WORK_CHANGED')
    for key in ('generation', 'participantId', 'resources'):
        if producer.get(key) != before.get(key):
            raise WorkError('SOURCE_SYNC_RECOVERY_PHASE_OWNER_CHANGED')
    for other_id, previous in intent['nativeSnapshot'].items():
        if other_id == producer_id:
            continue
        current = native._index(record)['producers'].get(other_id)
        if (not current or any(current.get(key) != previous.get(key) for key in
                ('generation', 'participantId', 'resources', 'records', 'restorations'))):
            raise WorkError('SOURCE_SYNC_RECOVERY_CONCURRENT_WORK_CHANGED')
    previous_records = set(before.get('records', {}))
    current_records = producer.get('records', {})
    if (not previous_records <= set(current_records) or
            any(current_records[key] != before['records'][key] for key in previous_records)):
        raise WorkError('SOURCE_SYNC_RECOVERY_NATIVE_HISTORY_CHANGED')
    later_keys = [key for key in current_records if key not in previous_records]
    later = [native._read_operation(recovery.coordinator, record['ticket'], key, current_records[key]) for key in later_keys]
    if not later or any(not op['startAttempted'] or not op['launcherExited'] or not op['quiescenceConfirmed'] for op in later):
        raise WorkError('SOURCE_SYNC_RECOVERY_NATIVE_WORK_UNCONFIRMED')
    loads = [op for op in later if op.get('effectContract') is not None]
    if any(op['purpose'] != 'owned-runtime-drain' and op not in loads for op in later):
        raise WorkError('SOURCE_SYNC_RECOVERY_UNACKNOWLEDGED_NATIVE_WORK: operation contract unavailable')
    expected_project = str(Path(phase['project']))
    expected_target = next((member['target'] for member in phase['members']
                            if member['name'].casefold() == phase['member'].casefold()), None)
    if expected_target is None:
        raise WorkError('SOURCE_SYNC_RECOVERY_MEMBER_CHANGED')
    expected_resource = recovery.coordinator.resources([expected_target])
    for operation in loads:
        effect = operation['effectContract']
        if (effect['kind'] != 'load-config-from-files' or str(Path(effect['project'])) != expected_project or
                effect['sourceFingerprint'] != phase['sourceFingerprint'] or
                effect['sourceCommit'] != phase['sourceCommit'] or effect['exportPath'] != phase['exportPath'] or
                effect['contentKind'] != phase['contentKind'] or effect['extensionName'] != phase['extensionName'] or
                recovery.coordinator.resources(operation['admissions']) != expected_resource):
            raise WorkError('SOURCE_SYNC_RECOVERY_EFFECT_CONTRACT_CHANGED')
    succeeded = [op for op in loads if op['outcome']['status'] == 'succeeded']
    if len(succeeded) != 1 or any(op['outcome']['status'] == 'pending' for op in loads) or loads[-1] != succeeded[0]:
        raise WorkError('SOURCE_SYNC_RECOVERY_NATIVE_OUTCOME_UNCONFIRMED')
    success = succeeded[0]
    source_proof = _verify_source_commit(phase, success['effectContract'])
    new_duties = []
    previous_duties = set(before.get('restorations', {}))
    current_duties = producer.get('restorations', {})
    if (not previous_duties <= set(current_duties) or
            any(current_duties[key] != before['restorations'][key] for key in previous_duties)):
        raise WorkError('SOURCE_SYNC_RECOVERY_RESTORATION_HISTORY_CHANGED')
    for key in current_duties:
        if key not in previous_duties:
            new_duties.append(key)
    expected_cursor = Path(expected_project) / Path(phase['exportPath']) / 'ConfigDumpInfo.xml'
    matching = []
    from . import restoration_journal
    for key in new_duties:
        duty = restoration_journal.read(recovery.coordinator, record['ticket'], key, current_duties[key])
        if duty['journalId'] == success['journalId'] and duty['kind'] == 'config-dump-info' and Path(duty['destination']) == expected_cursor:
            matching.append(key)
        else:
            raise WorkError('SOURCE_SYNC_RECOVERY_RESTORATION_UNSUPPORTED')
    if len(matching) != 1:
        raise WorkError('SOURCE_SYNC_RECOVERY_CURSOR_DUTY_REQUIRED')
    restoration_journal.commit_recovered_source_cursor(
        recovery, matching[0], project=expected_project, destination=str(expected_cursor))
    scopes = [scope for scope in success['ownedProcessScopes'] if scope.get('role') == 'native-invocation']
    if len(scopes) != 1:
        raise WorkError('SOURCE_SYNC_RECOVERY_NATIVE_SCOPE_AMBIGUOUS')
    effect = success['effectContract']
    status = 'fallback-succeeded' if effect['mode'] == 'full-fallback' else 'passed'
    failed_partial = any(op['effectContract']['mode'] == 'partial' and op['outcome']['status'] == 'failed' for op in loads)
    load_result = {'loaded': True, 'fileCount': 0, 'infoBasePath': expected_target['path'],
                   'infoBaseKind': expected_target['kind'], 'listFile': '', 'currentCommit': phase['sourceCommit'],
                   'lastLogPath': scopes[0]['logPath'], 'loadModeUsed': effect['mode'],
                   'partialLogPath': '', 'fullFallbackLogPath': scopes[0]['logPath'] if effect['mode'] == 'full-fallback' else '',
                   'configLoadStatus': status, 'partialError': 'recovered failed partial attempt' if failed_partial else '',
                   'fullFallbackError': '', 'normalizationRequired': True,
                   'sourceFingerprint': phase['sourceFingerprint'], 'sourceTreeObjectId': effect['sourceTreeObjectId'],
                   'loadReason': 'recovered-native-load', 'designerInvoked': True, 'enterpriseInvoked': False}
    result = {'loadResult': load_result, 'cursorSha256': digest(expected_cursor)}
    completed = _publish_recovered_completion(recovery, intent, result)
    return {'phase': completed, 'operation': success['journalId'] + '/' + success['id'],
            'cursorDuty': matching[0], 'effectContract': effect, 'sourceProof': source_proof}


def recover(recovery, journal, producers, observations):
    """Release a proven phase boundary; do not execute or complete the group."""
    from .access_recovery import VerifiedRecovery
    record = recovery._current()
    if record['owner']['operation'] != 'sync-dev-branches':
        raise WorkError('SOURCE_SYNC_RECOVERY_OPERATION_CHANGED')
    phases = journal.get('sourceSyncPhases', [])
    groups = {item['phase']['groupId'] for item in phases}
    if len(groups) != 1:
        raise WorkError('SOURCE_SYNC_RECOVERY_GROUP_AMBIGUOUS')
    context_phase = max(phases, key=lambda item: (item['acknowledgedAt'], item['sequence']))
    # All exact resources are inspected twice through the retained native
    # helper. Only unused, absent manager generations may omit an infobase.
    used = {key for op in journal['operations'] if op['startAttempted']
            for key in recovery.coordinator.resources(op['admissions'])}
    roots = [Path(member['project']) / '.agent-1c' / 'infobases' for member in context_phase['phase']['members']]
    if not observations:
        raise WorkError('NATIVE_RECOVERY_INSPECTION_UNCONFIRMED')
    for observation in observations:
        samples = observation['observation']['samples']
        if len(samples) != 2:
            raise WorkError('NATIVE_RECOVERY_INSPECTION_UNCONFIRMED')
        for sample in samples:
            if recovery.coordinator.resources(sample['resources']) != record['resources']:
                raise WorkError('NATIVE_RECOVERY_INSPECTION_SCOPE_CHANGED')
            for base in sample['resources']:
                path = Path(base['path'])
                unused = (recovery.coordinator.resources([base])[0] not in used and base['kind'] == 'file' and
                          path.parent in roots and re.fullmatch('vanessa-service-[a-f0-9]{32}', path.name) and
                          not base['directoryPresent'] and not base['databasePresent'])
                if base['sessionCount'] or (not unused and (not base['databasePresent'] or not base['exclusive'])):
                    raise WorkError('NATIVE_RECOVERY_DATABASE_STILL_IN_USE')
    matching = [item for item in phases if item['nativeSnapshot'] == snapshot(record)]
    reconciled = None
    if not matching:
        reconciled = _reconcile_completed_load(recovery, journal)
        record = recovery._current()
        journal = native.inspect(recovery.coordinator, record)
        phases = journal.get('sourceSyncPhases', [])
        matching = [item for item in phases if item['nativeSnapshot'] == snapshot(record)]
    if not matching:
        raise WorkError('SOURCE_SYNC_RECOVERY_UNACKNOWLEDGED_NATIVE_WORK')
    selected = max(matching, key=lambda item: (item['acknowledgedAt'], item['sequence']))
    if any(duty['status'] == 'pending' for duty in journal['restoration']['duties']):
        raise WorkError('SOURCE_SYNC_RECOVERY_RESTORATION_PENDING')
    return VerifiedRecovery(tuple(record['resources']), {
        'adapter': 'workflow-source-sync-phase', 'originalOutcome': 'interrupted',
        'resolution': 'native-work-covered-by-phase-boundary', 'groupId': selected['phase']['groupId'],
        'stepId': selected['phase']['stepId'], 'member': selected['phase']['member'], 'step': selected['phase']['step'],
        'phaseStatus': selected['phase']['status'], 'producers': producers, 'nativeObservations': observations,
        'reconciledLoad': reconciled,
        'preservedResult': 'database, source, group plan and branch state left unchanged',
        'verification': 'admission released; repeat the group helper to reconcile its saved phases; no business replay',
    })
