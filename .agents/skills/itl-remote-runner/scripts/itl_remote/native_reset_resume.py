"""Continue the original reset under recovery fencing, never reacquire its DB."""
import os
from pathlib import Path
import sys
import time
import uuid
import json

from .common import OwnedProcess, WorkError, capture, digest, git_path_list, read_json, write_json
from . import native_journal, native_reset, native_continuation
from .access_recovery import VerifiedRecovery


def _checkout(context):
    project = Path(context['project'])
    def git(*arguments):
        return capture(['git', '-C', str(project), *arguments], timeout=30).decode('utf-8').strip()
    if git('symbolic-ref', '--quiet', '--short', 'HEAD') != context['branch']:
        raise WorkError('NATIVE_RESET_RECOVERY_CHECKOUT_CHANGED')
    if (git_path_list(project, ['diff', '--name-only', '-z', 'HEAD', '--']) or
            git_path_list(project, ['ls-files', '--others', '--exclude-standard', '-z'])):
        raise WorkError('NATIVE_RESET_RECOVERY_USER_CHANGES_PRESENT')
    head, tree = git('rev-parse', 'HEAD'), git('rev-parse', 'HEAD^{tree}')
    phase = native_reset.PHASES.index(context['phase'])
    expected = context['newHead'] if phase >= 2 else context['oldHead']
    if head != expected and not (phase == 1 and tree == context['masterTree']):
        raise WorkError('NATIVE_RESET_RECOVERY_HEAD_CHANGED')
    if phase >= 2 and tree != context['masterTree']:
        raise WorkError('NATIVE_RESET_RECOVERY_TREE_CHANGED')
    if git('rev-parse', context['masterCommit'] + '^{tree}') != context['masterTree']:
        raise WorkError('NATIVE_RESET_RECOVERY_MASTER_CHANGED')
    return {'head': head, 'tree': tree}


def recover(recovery, journal, producers):
    from .native_recovery import inspect_native_work
    from .native_completion import assert_quiescent
    current = recovery._current()
    checkpoints = native_reset.inspect(recovery.coordinator, current)
    if not checkpoints or current['owner']['operation'] != 'reset-dev-branch':
        raise WorkError('NATIVE_RESET_RECOVERY_CHECKPOINT_REQUIRED')
    checkpoint = checkpoints[-1]
    context = checkpoint['context']
    if any(duty['status'] == 'pending' for duty in journal['restoration']['duties']):
        raise WorkError('NATIVE_RESET_RECOVERY_RESTORATION_PENDING')
    before_checkout = _checkout(context)
    before = inspect_native_work(recovery, journal)
    assert_quiescent(recovery, journal, before, context['project'])
    plan = native_continuation.read(recovery.coordinator, current, checkpoint['continuation'])['plan']
    runtime = Path(__file__).resolve().parent.parent
    helper = runtime.parent.parent / '1c-workflow/scripts/agent-1c.ps1'
    worker = runtime / 'Resume-NativeReset.ps1'
    paths = [worker, helper, *sorted((helper.parent / 'lib').glob('*.ps1'))]
    if not helper.is_file() or len(paths) < 3:
        raise WorkError('NATIVE_RESET_RECOVERY_HELPER_UNAVAILABLE')
    helper_files = [{'path': str(path), 'sha256': digest(path)} for path in paths]
    output = recovery.coordinator.root / 'recovery-observations' / recovery.ticket / recovery.attempt
    resume_id = uuid.uuid4().hex
    envelope = {'schemaVersion': 1, 'resumeId': resume_id, 'checkpoint': checkpoint, 'plan': plan,
                'coordinator': str(recovery.coordinator.root), 'helperPath': str(helper), 'helperFiles': helper_files,
                'python': sys.executable, 'output': str(output)}
    context_path = output / (resume_id + '.context.json')
    write_json(context_path, envelope)
    with recovery.coordinator.mutex(time.monotonic() + 30, recovery.cancelled):
        current = recovery._current()
        if native_reset.inspect(recovery.coordinator, current)[-1]['reference'] != checkpoint['reference']:
            raise WorkError('NATIVE_RESET_RECOVERY_CHECKPOINT_CHANGED')
        current['recoveryAttempts'][-1]['resetResume'] = {
            'checkpoint': checkpoint['reference'], 'continuation': checkpoint['continuation'],
            'contextPath': str(context_path), 'contextSha256': digest(context_path), 'resumeId': resume_id}
        recovery.coordinator.save(current)
        recovery.record = current
    shell = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
    private_input = (json.dumps(recovery.proof(), ensure_ascii=True) + '\n').encode('ascii')
    log = output / (resume_id + '.log')
    try:
        with OwnedProcess([str(shell), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(worker),
                           '-ContextPath', str(context_path)], output, log, input_data=private_input) as process:
            process.wait(3600, recovery.cancelled)
    except WorkError as error:
        status_path = output / (resume_id + '.status.json')
        detail = str(error)
        try:
            if status_path.is_file() and status_path.stat().st_size <= 65536:
                status = read_json(status_path)
                if isinstance(status, dict) and isinstance(status.get('errorMessage'), str) and status['errorMessage']:
                    detail = 'stage=' + str(status.get('stage', 'unknown')) + '; ' + status['errorMessage'][:4000]
        except (OSError, ValueError, WorkError):
            pass
        raise WorkError('NATIVE_RESET_RECOVERY_WORKER_FAILED: ' + detail + '; log=' + str(log) +
                        '; status=' + str(status_path) + '; database admission retained') from error
    finally:
        private_input = None
    if digest(context_path) != recovery._current()['recoveryAttempts'][-1]['resetResume']['contextSha256']:
        raise WorkError('NATIVE_RESET_RECOVERY_CONTEXT_CHANGED')
    result_path = output / (resume_id + '.result.json')
    result = read_json(result_path)
    if (not isinstance(result, dict) or result.get('schemaVersion') != 1 or result.get('resumeId') != resume_id or
            result.get('ticket') != recovery.ticket or result.get('fromCheckpoint') != checkpoint['reference'] or
            result.get('operation') != 'reset-dev-branch' or result.get('resumed') is not True):
        raise WorkError('NATIVE_RESET_RECOVERY_RESULT_UNCONFIRMED')
    current = recovery._current()
    after_journal = native_journal.inspect(recovery.coordinator, current, resolve_helpers=True)
    completed = after_journal['completions'].get(result.get('producerId'))
    latest = after_journal['resetCheckpoints'][-1]
    if (not completed or completed['operation'] != 'reset-dev-branch' or completed['resources'] != current['resources'] or
            latest['context']['phase'] != 'complete' or
            any(latest['context'][key] != context[key] for key in native_reset.STABLE) or
            any(duty['status'] == 'pending' for duty in after_journal['restoration']['duties'])):
        raise WorkError('NATIVE_RESET_RECOVERY_COMPLETION_UNCONFIRMED')
    after_checkout = _checkout(latest['context'])
    # A reset may intentionally replace the installed helper tree. Other code
    # changes during recovery are not attributed to that lifecycle transition.
    for item in helper_files:
        path = Path(item['path'])
        if (not path.is_file() or digest(path) != item['sha256']) and not (path.is_relative_to(Path(context['project'])) and
                                                  after_checkout['tree'] == context['masterTree']):
            raise WorkError('NATIVE_RESET_RECOVERY_HELPER_CHANGED')
    after = inspect_native_work(recovery, after_journal)
    assert_quiescent(recovery, after_journal, after, context['project'])
    return VerifiedRecovery(tuple(current['resources']), {
        'adapter': 'workflow-reset-continuation', 'originalOutcome': 'interrupted',
        'resolution': 'original reset continued from its confirmed phase',
        'fromCheckpoint': checkpoint['reference'], 'toCheckpoint': latest['reference'],
        'producerId': result['producerId'], 'producers': producers,
        'result': {'path': str(result_path), 'sha256': digest(result_path)},
        'beforeCheckout': before_checkout, 'afterCheckout': after_checkout,
        'before': before, 'after': after, 'helperInputs': helper_files,
        'verification': 'reset completion, not a fresh verification pass',
    })
