"""Recovery for an explicitly configured, dedicated Linux Docker host."""
from __future__ import annotations

import argparse
import contextlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

LABEL = 'itland.mcp.host'


def command(arguments, timeout=30):
    result = subprocess.run(arguments, capture_output=True, text=True,
                            encoding='utf-8', errors='strict', timeout=timeout)
    if result.returncode:
        # Compose output can contain interpolated secrets; keep it out of status.
        raise RuntimeError(f'{arguments[0]} failed with exit code {result.returncode}')
    return result.stdout


def validate_config(config):
    names = config.get('containers', [])
    if (not re.fullmatch(r'[a-z0-9][a-z0-9.-]{0,63}', config.get('hostId', ''))
            or not 1 <= len(names) <= 16 or len(set(names)) != len(names)
            or any(not re.fullmatch(r'itl-[a-z0-9][a-z0-9-]{0,120}', n) for n in names)):
        raise ValueError('Invalid host identity or container allowlist')
    for field in ('composePath', 'lockPath', 'statusPath'):
        if not Path(config[field]).is_absolute():
            raise ValueError(f'{field} must be absolute')


@contextlib.contextmanager
def maintenance_lock(path, blocking=False):
    import fcntl
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a', encoding='utf-8') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def validate_compose(config, run):
    document = json.loads(run(['docker', 'compose', '-f', config['composePath'],
                               'config', '--format', 'json']))
    services = list(document.get('services', {}).values())
    if len(services) != len(config['containers']) or {s.get('container_name') for s in services} != set(config['containers']):
        raise ValueError('Compose container set differs from the allowlist')
    for service in services:
        if service.get('labels', {}).get(LABEL) != config['hostId']:
            raise ValueError('Compose host ownership mismatch')
        if not re.search(r'@sha256:[0-9a-f]{64}$', service.get('image', '')):
            raise ValueError('Compose images must be pinned by digest')


def recover(config, run=command):
    validate_config(config)
    actions = []
    try:
        run(['docker', 'info', '--format', '{{.ServerVersion}}'], timeout=15)
    except (RuntimeError, subprocess.TimeoutExpired):
        # This backend is for a dedicated Docker VM, not a shared daemon.
        run(['systemctl', 'restart', 'docker.service'], timeout=90)
        run(['docker', 'info', '--format', '{{.ServerVersion}}'], timeout=15)
        actions.append('docker-restarted')
    present = set(run(['docker', 'container', 'ls', '-a', '--format', '{{.Names}}']).splitlines())
    states = []
    missing = []
    # Validate every existing identity before touching any container.
    for name in config['containers']:
        if name not in present:
            missing.append(name)
            continue
        item = json.loads(run(['docker', 'inspect', name]))[0]
        if (item.get('Name') != '/' + name
                or item.get('Config', {}).get('Labels', {}).get(LABEL) != config['hostId']
                or not re.fullmatch(r'[0-9a-f]{64}', item.get('Id', ''))):
            raise ValueError('Existing container ownership mismatch: ' + name)
        states.append((name, item['Id'], item['State']))
    if missing:
        validate_compose(config, run)
        run(['docker', 'compose', '-f', config['composePath'], 'up', '-d',
             '--no-build', '--pull', 'never'], timeout=90)
        actions.append('compose-restored')
        # Compose also starts dependencies; inspect on the next timer tick.
        return {'status': 'recovered', 'actions': actions, 'missing': missing}
    for name, identity, state in states:
        if state.get('Status') in ('exited', 'dead', 'created'):
            run(['docker', 'start', identity])
            actions.append('started:' + name)
        elif state.get('Status') == 'running' and state.get('Health', {}).get('Status') == 'unhealthy':
            run(['docker', 'restart', '--time', '20', identity], timeout=45)
            actions.append('restarted:' + name)
        elif state.get('Status') in ('paused', 'restarting', 'removing'):
            # Docker owns a restart already in progress; do not race it.
            actions.append('pending:' + name)
    return {'status': 'recovered' if actions else 'healthy', 'actions': actions}


def write_status(path, status):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + str(os.getpid()) + '.tmp')
    temporary.write_text(json.dumps(status, ensure_ascii=False) + '\n', encoding='utf-8')
    os.replace(temporary, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    parser.add_argument('--hold', nargs=argparse.REMAINDER,
                        help='Run an indexing or maintenance command under the same OS lock')
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text(encoding='utf-8'))
    validate_config(config)
    if args.hold is not None:
        if not args.hold:
            parser.error('--hold requires a command')
        with maintenance_lock(config['lockPath'], blocking=True):
            return subprocess.call(args.hold)
    started = time.time()
    with maintenance_lock(config['lockPath']) as admitted:
        if not admitted:
            status = {'status': 'maintenance-active', 'actions': []}
        else:
            try:
                status = recover(config)
            except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
                status = {'status': 'failed', 'error': str(error), 'actions': []}
        status.update(hostId=config['hostId'], completedAt=time.time(), elapsedSeconds=round(time.time() - started, 3))
        write_status(config['statusPath'], status)
        print(json.dumps(status, ensure_ascii=False))
        return 1 if status['status'] == 'failed' else 0


if __name__ == '__main__':
    raise SystemExit(main())
