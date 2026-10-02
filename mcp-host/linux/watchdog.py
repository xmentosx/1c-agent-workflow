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

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from endpoint_identity import check_endpoint, SAFE_TOOLS

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
    endpoints = config.get('mcpEndpoints', [])
    if (not isinstance(endpoints, list)
            or any(not isinstance(item, dict) or not {'container', 'url', 'hostPort', 'healthTool'} <= item.keys()
                   or not isinstance(item['hostPort'], int) or not isinstance(item['url'], str)
                   for item in endpoints)):
        raise ValueError('MCP endpoint entries require container, URL, host port and safe health tool')
    if (len(endpoints) > len(names) or len({item['container'] for item in endpoints}) != len(endpoints)
            or any(item['container'] not in names or item['healthTool'] not in SAFE_TOOLS
                   or not 1 <= item['hostPort'] <= 65535 for item in endpoints)):
        raise ValueError('MCP endpoint set must use the owned container allowlist and safe health tools')


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


def recover(config, run=command, probe=check_endpoint):
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
    endpoints = []
    state_by_name = {name: state for name, identity, state in states}
    for endpoint in config.get('mcpEndpoints', []):
        name = endpoint['container']
        if state_by_name[name].get('Status') != 'running':
            endpoints.append({'container': name, 'status': 'pending'})
            continue
        def qualify():
            return probe(name, endpoint['url'], endpoint['hostPort'], endpoint['healthTool'],
                         endpoint.get('healthArguments'), timeout=5, run=run)
        proof = qualify()
        if proof['status'] == 'mismatch':
            if 'restarted:' + name in actions:
                raise RuntimeError('MCP public identity still mismatches after one restart: ' + name)
            # Same owner/OS lock as existing recovery; immutable ID must match the
            # identity validated for the entire allowlist before any mutation.
            identity = next(identity for target, identity, state in states if target == name)
            if proof.get('container_id') != identity:
                raise ValueError('MCP probe container identity changed: ' + name)
            run(['docker', 'restart', '--time', '20', identity], timeout=45)
            actions.append('endpoint-restarted:' + name)
            proof = qualify()
            if proof['status'] != 'matched':
                raise RuntimeError('MCP public identity did not recover after one restart: ' + name
                                   + '; inspect forwarding and retry the existing watchdog')
        endpoints.append(dict(proof, container=name))
    degraded = any(item['status'] != 'matched' for item in endpoints)
    return {'status': 'degraded' if degraded else ('recovered' if actions else 'healthy'),
            'actions': actions, 'endpoints': endpoints}


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
        return 1 if status['status'] in ('failed', 'degraded') else 0


if __name__ == '__main__':
    raise SystemExit(main())
