"""Release admission after an acknowledged extension commit, without replay."""
from datetime import datetime
from pathlib import Path
import re

from .access_recovery import VerifiedRecovery
from .common import WorkError


def _time(value):
    try:
        result = datetime.fromisoformat(value)
        if result.tzinfo is None:
            raise ValueError('timezone required')
        return result
    except (TypeError, ValueError) as error:
        raise WorkError('NATIVE_RECOVERY_COMPLETION_ORDER_UNKNOWN') from error


def committed_initialization(recovery, journal, producers, observations):
    """The indexed commit attests to saved state; live checks attest to release.

    This does not revalidate the business result or overwrite later source edits.
    Removed completed snapshots are expected and are never needed for this path.
    """
    current = recovery._current()
    duties = journal['restoration']['duties']
    snapshots = [duty for duty in duties if duty['kind'] == 'infobase-snapshot']
    if (current['owner']['operation'] != 'init-dev-branch-extension' or len(snapshots) != 1 or
            any(duty['status'] == 'pending' for duty in duties)):
        raise WorkError('NATIVE_RECOVERY_COMPLETION_CONTRACT_REQUIRED')
    committed = snapshots[0]
    if (committed['status'] != 'committed' or committed['policy'] != 'on-failure' or
            committed['restoreOperation'] or committed['operation'] != 'init-dev-branch-extension' or
            recovery.coordinator.resources(committed['resources']) != current['resources']):
        raise WorkError('NATIVE_RECOVERY_COMPLETION_CONTRACT_REQUIRED')
    completed_at = _time(committed['updatedAt'])
    if completed_at < _time(committed['createdAt']):
        raise WorkError('NATIVE_RECOVERY_COMPLETION_ORDER_UNKNOWN')
    primary = recovery.coordinator.resources([committed['infoBase']])[0]
    resources = {recovery.coordinator.resources([base])[0]: base for base in committed['resources']}
    project = Path(committed['project'])
    services = set()
    for resource, base in resources.items():
        if resource == primary:
            continue
        path = Path(base['path'])
        if (base['kind'] != 'file' or path.parent != project / '.agent-1c' / 'infobases' or
                not re.fullmatch(r'vanessa-service-[a-f0-9]{32}', path.name)):
            raise WorkError('NATIVE_RECOVERY_ADDITIONAL_DATABASE_COMPLETION_REQUIRED')
        services.add(resource)
    started = set()
    for operation in journal['operations']:
        if (operation['project'] != committed['project'] or
                operation['operation'] != committed['operation'] or
                _time(operation['updatedAt']) > completed_at):
            raise WorkError('NATIVE_RECOVERY_WORK_AFTER_COMPLETION')
        if operation['startAttempted']:
            if not operation['launcherExited'] or not operation['quiescenceConfirmed']:
                raise WorkError('NATIVE_RECOVERY_COMPLETION_NATIVE_WORK_UNCONFIRMED')
            started.update(recovery.coordinator.resources(operation['admissions']))
    if primary not in started or not started <= set(resources):
        raise WorkError('NATIVE_RECOVERY_COMPLETION_NATIVE_WORK_UNCONFIRMED')
    if not observations:
        raise WorkError('NATIVE_RECOVERY_INSPECTION_UNCONFIRMED')
    unused = services - started
    for observation in observations:
        for sample in observation['observation']['samples']:
            for base in sample['resources']:
                key = recovery.coordinator.resources([base])[0]
                unused_absent = key in unused and not base['directoryPresent'] and not base['databasePresent']
                if base['sessionCount'] or (not unused_absent and (not base['databasePresent'] or not base['exclusive'])):
                    raise WorkError('NATIVE_RECOVERY_DATABASE_STILL_IN_USE')
    return VerifiedRecovery(tuple(current['resources']), {
        'adapter': 'workflow-committed-extension-initialization', 'originalOutcome': 'interrupted',
        'resolution': 'commit-acknowledged-before-interruption', 'producers': producers,
        'committedDuty': committed['journalId'] + '/' + committed['id'],
        'originalRecordRevision': journal['recordRevision'],
        'preservedResult': 'database, source, branch state and environment left unchanged',
        'verification': 'no new verification; stored initialization commit is not fresh passed',
    })
