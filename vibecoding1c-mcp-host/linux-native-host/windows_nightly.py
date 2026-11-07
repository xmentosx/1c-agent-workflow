"""Windows task: guarded Designer export and refresh through a read-only share."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time


EXPORT_TIMEOUT_SECONDS = 28800
# The export job owns process lifetime only. Memory admission stays with the
# host, so this policy neither limits nor samples the Designer process tree.
EXPORT_PROCESS_LIMITS = {'maxWorkerMemoryMb': 1048576, 'maxProcessMemoryMb': 1048576,
                         'maxJobMemoryMb': 1048576, 'maxGrowthMb': 1048576,
                         'minAvailableMemoryMb': 1, 'maxCommittedPercent': 100}


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + str(os.getpid()) + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
    os.replace(temporary, path)


def run(arguments, **options):
    if not options.get('capture_output'):
        options.setdefault('stdout', sys.stdout)
        options.setdefault('stderr', sys.stderr)
    return subprocess.run(arguments, check=True, encoding='utf-8', errors='strict',
                          creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0, **options)


def run_owned_export(arguments, env, output, timeout):
    """Run the export in a kill-on-close job: a timeout ends PowerShell and every 1cv8.exe it started."""
    from itl_remote.common import OwnedProcess
    sys.stdout.flush()
    sys.stderr.flush()
    with OwnedProcess(arguments, None, output, env, EXPORT_PROCESS_LIMITS) as owned:
        try:
            code = owned.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Leaving the block closes the job before the export-base guard is released.
            raise subprocess.TimeoutExpired(arguments, timeout) from None
    if code:
        raise subprocess.CalledProcessError(code, arguments)


def ssh_options(config):
    return ['-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=15',
            '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=6',
            '-o', 'UserKnownHostsFile=' + config['knownHostsFile'], '-o', 'HostKeyAlias=' + config['hostKeyAlias'],
            '-i', config['identityFile']]


def export_and_refresh(config, configuration, config_path, guard_type, canonical_resources, force=False, *, output):
    config_id = configuration['configId']
    if not re.fullmatch('[a-z0-9][a-z0-9-]{0,63}', config_id):
        raise ValueError('Invalid configuration id')
    root = Path(config['rootPath']).resolve()
    source = Path(configuration['sourcePath']).resolve() / configuration.get('mainConfigPath', 'src/cf')
    base = Path(configuration['dump']['sourceInfoBasePath']).resolve()
    if not source.is_relative_to(root / 'sources') or not base.is_relative_to(root / 'bases'):
        raise ValueError('Export paths are outside the dedicated host root')
    if not (base / '1Cv8.1CD').is_file():
        raise ValueError('The dedicated export infobase must be provisioned first')
    env = dict(os.environ, PYTHONUTF8='1', PYTHONIOENCODING='utf-8')
    resources = canonical_resources([{'kind': 'file', 'path': str(base)}])
    with guard_type(Path(config['guardRoot']), resources, 'dump-config', timeout=3600) as guard:
        proof = guard.context()
        env['ITL_EXECUTION_CONTEXT'] = proof['encoded']
        env['ITL_EXECUTION_CONTEXT_KEY'] = base64.urlsafe_b64encode(proof['key']).decode('ascii')
        run_owned_export(['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
                          str(Path(config['workflowPath']) / 'vibecoding1c-mcp-host/export-1c-config-dump.ps1'),
                          '-ConfigPath', str(config_path), '-ConfigId', config_id],
                         env, output, EXPORT_TIMEOUT_SECONDS)
        if not all((source / name).is_file() for name in ('Configuration.xml', 'ConfigDumpInfo.xml')):
            raise ValueError('Designer export did not complete')
        # Retain the exact export-base guard through the Linux refresh so a
        # second authorized Designer export cannot change the shared input.
        return refresh_linux(config, config_id, force)


def refresh_linux(config, config_id, force):
    target = config['linuxUser'] + '@' + config['linuxHost']
    runtime = int(config.get('refreshRuntimeSeconds', 43200))
    if runtime <= 0:
        raise ValueError('Refresh runtime must be positive')
    command = ['sudo', 'systemd-run', '--quiet', '--wait', '--pipe', '--collect', '--service-type=exec',
               '--unit=itl-mcp-refresh-' + config_id, '--property=RuntimeMaxSec=' + str(runtime), '--property=TimeoutStopSec=120',
               'python3', '/opt/itl-mcp/host/refresh.py', '--host-config', '/opt/itl-mcp/host.config.json',
               '--job-config', '/opt/itl-mcp/refresh.config.json', '--config-id', config_id]
    if force:
        command.append('--force')
    result = run([config['sshPath'], *ssh_options(config), target, shlex.join(command)],
                 capture_output=True, timeout=max(config.get('timeoutSeconds', 46800), runtime + 120))
    status = json.loads(result.stdout)
    if status.get('state') not in ('succeeded', 'unchanged'):
        raise RuntimeError('Linux refresh did not complete')
    return status


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    parser.add_argument('--config-id')
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    config_path = Path(args.config)
    config = json.loads(config_path.read_text(encoding='utf-8-sig'))
    log_path = Path(config['rootPath']) / 'logs/nightly' / (time.strftime('%Y%m%d-%H%M%S') + '.log')
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log = log_path.open('a', encoding='utf-8', buffering=1)
    sys.stdout = log
    sys.stderr = log
    sys.path.insert(0, str(Path(config['workflowPath']) / '.agents/skills/itl-remote-runner/scripts'))
    from itl_remote.execution_guard import ExecutionGuard, canonical_resources
    configurations = [item for item in config['configurations'] if not args.config_id or item['configId'] == args.config_id]
    if not configurations:
        raise ValueError('Unknown configuration')
    state_path = Path(config['rootPath']) / 'state/nightly-index-state.json'
    state = {'state': 'running', 'startedAt': time.time(), 'configurations': []}
    save(state_path, state)
    failures = []
    # One configuration failure must not prevent the other from refreshing.
    for configuration in configurations:
        config_id = configuration['configId']
        state['currentConfiguration'] = config_id
        save(state_path, state)
        print('REFRESH_STARTED=' + config_id, flush=True)
        try:
            status = export_and_refresh(config, configuration, config_path, ExecutionGuard, canonical_resources,
                                        args.force, output=log_path)
            state['configurations'].append(status)
            print('REFRESH_COMPLETED=' + json.dumps(status, ensure_ascii=False), flush=True)
        except Exception as error:
            failures.append(config_id)
            state['configurations'].append({'configId': config_id, 'state': 'failed', 'error': str(error)})
            print('REFRESH_FAILED=' + config_id, flush=True)
        save(state_path, state)
    state.update(state='failed' if failures else 'succeeded', completedAt=time.time(), failedConfigurations=failures)
    save(state_path, state)
    return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
