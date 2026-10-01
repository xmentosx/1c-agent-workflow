"""Windows task: guarded Designer export, immutable transfer, Linux refresh."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tarfile
import time


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


def ssh_options(config):
    return ['-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=15',
            '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=6',
            '-o', 'UserKnownHostsFile=' + config['knownHostsFile'], '-o', 'HostKeyAlias=' + config['hostKeyAlias'],
            '-i', config['identityFile']]


def export_and_refresh(config, configuration, config_path, guard_type, canonical_resources, force=False):
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
        run(['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
             str(Path(config['workflowPath']) / 'vibecoding1c-mcp-host/export-1c-config-dump.ps1'),
             '-ConfigPath', str(config_path), '-ConfigId', config_id], env=env, timeout=28800)
    if not all((source / name).is_file() for name in ('Configuration.xml', 'ConfigDumpInfo.xml')):
        raise ValueError('Designer export did not complete')
    archive_root = root / 'archives'
    archive_root.mkdir(parents=True, exist_ok=True)
    archive = archive_root / (config_id + '-' + time.strftime('%Y%m%d-%H%M%S') + '.tar.gz')
    with tarfile.open(archive, 'w:gz', compresslevel=1) as handle:
        handle.add(source, arcname='src/cf')
    with archive.open('rb') as handle:
        archive_hash = hashlib.file_digest(handle, 'sha256').hexdigest()
    remote_archive = '/var/lib/itl-mcp/incoming/' + config_id + '-' + archive_hash + '.tar.gz'
    target = config['linuxUser'] + '@' + config['linuxHost']
    run([config['scpPath'], '-q', *ssh_options(config), str(archive), target + ':' + remote_archive], timeout=3600)
    command = ['sudo', 'systemd-run', '--quiet', '--wait', '--pipe', '--collect', '--service-type=exec',
               '--unit=itl-mcp-refresh-' + config_id, '--property=RuntimeMaxSec=43200', '--property=TimeoutStopSec=120',
               'python3', '/opt/itl-mcp/host/refresh.py', '--host-config', '/opt/itl-mcp/host.config.json',
               '--job-config', '/opt/itl-mcp/refresh.config.json', '--config-id', config_id,
               '--archive', remote_archive, '--sha256', archive_hash]
    if force:
        command.append('--force')
    result = run([config['sshPath'], *ssh_options(config), target, shlex.join(command)],
                 capture_output=True, timeout=config.get('timeoutSeconds', 46800))
    status = json.loads(result.stdout)
    if status.get('state') not in ('succeeded', 'unchanged'):
        raise RuntimeError('Linux refresh did not complete')
    # Keep the newest two successful transfer archives for this configuration.
    for old in sorted(archive_root.glob(config_id + '-*.tar.gz'), key=lambda p: p.stat().st_mtime, reverse=True)[2:]:
        if old.parent.resolve() != archive_root.resolve():
            raise ValueError('Archive cleanup escaped the owned directory')
        old.unlink()
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
            status = export_and_refresh(config, configuration, config_path, ExecutionGuard, canonical_resources, args.force)
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
