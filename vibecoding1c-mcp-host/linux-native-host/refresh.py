"""Deploy a completed Designer export and refresh native Code and Graph."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import time
import urllib.error

from mcp_client import Client
from watchdog import LABEL, command, maintenance_lock, validate_config, write_status


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def extract_export(archive, destination):
    with tarfile.open(archive, 'r:gz') as handle:
        members = handle.getmembers()
        for item in members:
            path = Path(item.name)
            if (path.is_absolute() or '..' in path.parts or item.issym() or item.islnk()
                    or not (item.isdir() or item.isfile()) or path.parts[:2] != ('src', 'cf')):
                raise ValueError('Export archive contains an unsafe entry')
        handle.extractall(destination, members=members, filter='data')
    root = Path(destination) / 'src' / 'cf'
    if not all((root / name).is_file() for name in ('Configuration.xml', 'ConfigDumpInfo.xml')):
        raise ValueError('Export archive is incomplete')
    if not any(root.rglob('*.bsl')):
        raise ValueError('Export archive contains no BSL modules')
    return root


def input_fingerprint(source, report):
    result = hashlib.sha256()
    for path in sorted(source.rglob('*')):
        if path.is_file() and path.name != 'ConfigDumpInfo.xml':
            result.update(path.relative_to(source).as_posix().encode('utf-8') + b'\0')
            result.update(bytes.fromhex(digest(path)))
    result.update(bytes.fromhex(digest(report)))
    return result.hexdigest()


def code_phase(result):
    data = result.get('data', {})
    indexing = data.get('indexing', {})
    if indexing.get('running'):
        return 'running'
    if indexing.get('error') or indexing.get('last_outcome') in ('failed', 'cancelled'):
        raise RuntimeError('Code indexing failed')
    if indexing.get('last_outcome') != 'completed':
        return 'pending'
    provider = data.get('embedding_provider', {})
    if provider.get('status') != 'ok' or provider.get('local_active') or provider.get('provider') != 'remote':
        raise RuntimeError('Code remote embedding provider is not healthy')
    counts = data.get('collections', {})
    if not counts.get('metadata') or not counts.get('code'):
        raise RuntimeError('Code index is empty')
    if data.get('vector_store_health', {}).get('terminal'):
        raise RuntimeError('Code vector store has a terminal failure')
    return 'completed'


def graph_phase(result):
    data = result.get('data', {})
    if data.get('metadata_source', {}).get('code') == 'metadata_source_unavailable':
        raise RuntimeError('Graph metadata source is unavailable')
    tasks = data.get('background_tasks', {})
    if not tasks:
        return 'pending'
    failed = [name for name, task in tasks.items() if task.get('status') in ('failed', 'error')
              or (task.get('error') and task.get('status') not in ('completed', 'skipped'))]
    if failed:
        raise RuntimeError('Graph indexing failed: ' + ', '.join(failed))
    if data.get('any_running') or any(task.get('status') in ('running', 'pending', 'in_progress') for task in tasks.values()):
        return 'running'
    required = ('metadata_ingest', 'bsl_code_graph', 'vector_indexing', 'routine_embedding_indexing')
    if any(tasks.get(name, {}).get('status') not in ('completed', 'succeeded') for name in required):
        raise RuntimeError('Graph required indexing lanes are incomplete')
    if data.get('service_mode', {}).get('graph_only'):
        raise RuntimeError('Graph vector indexing is disabled')
    return 'completed'


def wait_ready(url, deadline):
    while time.monotonic() < deadline:
        try:
            return Client(url)
        except (OSError, urllib.error.URLError, RuntimeError):
            time.sleep(5)
    raise RuntimeError('MCP did not become ready before the deadline')


def container_identity(host, name, config_id):
    if name not in host['containers']:
        raise ValueError('Indexing container is not allowlisted')
    item = json.loads(command(['docker', 'inspect', name]))[0]
    labels = item.get('Config', {}).get('Labels', {})
    if (item.get('Name') != '/' + name or labels.get(LABEL) != host['hostId']
            or labels.get('itland.mcp.config') != config_id
            or not re.fullmatch('[0-9a-f]{64}', item.get('Id', ''))):
        raise ValueError('Indexing container ownership mismatch')
    return item['Id']


def refresh(host, job, config_id, archive, archive_hash, force=False):
    if digest(archive) != archive_hash:
        raise ValueError('Export archive checksum mismatch')
    selected = [item for item in job['configurations'] if item['configId'] == config_id]
    if len(selected) != 1:
        raise ValueError('Unknown or duplicate configuration')
    item = selected[0]
    data_root = Path(job['dataRoot']).resolve()
    source = Path(item['sourcePath']).resolve()
    metadata = Path(item['metadataPath']).resolve()
    if (not source.is_relative_to(data_root / 'sources') or not metadata.is_relative_to(data_root / 'metadata')
            or not source.is_dir() or not metadata.is_dir()):
        raise ValueError('Deployment directories are outside the dedicated data root')
    status_path = data_root / 'refresh-state' / (config_id + '.json')
    previous = json.loads(status_path.read_text(encoding='utf-8')) if status_path.is_file() else {}
    status = {'configId': config_id, 'state': 'running', 'stage': 'validate-export', 'startedAt': time.time(),
              'previousIndexedAt': previous.get('indexedAt'), 'archiveSha256': archive_hash}
    write_status(status_path, status)
    try:
        with tempfile.TemporaryDirectory(prefix=config_id + '-', dir=data_root / 'incoming') as temporary:
            staged = Path(temporary)
            staged_source = extract_export(archive, staged)
            report_dir = staged / 'metadata'
            generator_config = {'repoPath': str(staged), 'mainConfigPath': 'src/cf', 'mainConfigRequired': True,
                                'extensionPath': '', 'extensionRequired': False, 'outputPath': str(report_dir),
                                'reportFileName': 'Report.txt', 'encoding': 'utf-8', 'warningsAsErrors': False,
                                'buildXmlOverrides': True, 'diagnosticsPath': str(staged / 'diagnostics'),
                                'logsPath': str(staged / 'logs')}
            generator_path = staged / 'generator.json'
            generator_path.write_text(json.dumps(generator_config, ensure_ascii=False), encoding='utf-8')
            status['stage'] = 'generate-report'; write_status(status_path, status)
            generator_log = data_root / 'refresh-state' / (config_id + '-report.log')
            with generator_log.open('w', encoding='utf-8') as log:
                subprocess.run(['python3', job['metadataGenerator'], '--config', str(generator_path)],
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=1800)
            report = report_dir / 'Report.txt'
            if not report.is_file() or report.stat().st_size < 100:
                raise ValueError('Metadata report was not created')
            fingerprint = input_fingerprint(staged_source, report)
            status['inputFingerprint'] = fingerprint
            if not force and previous.get('state') in ('succeeded', 'unchanged') and previous.get('inputFingerprint') == fingerprint:
                status.update(state='unchanged', stage='completed', indexedAt=previous['indexedAt'], completedAt=time.time())
                write_status(status_path, status)
                return status
            # Validate both identities before stopping either service. Neo4j is preserved.
            identities = [container_identity(host, item[kind + 'Container'], config_id) for kind in ('code', 'graph')]
            status['stage'] = 'deploy-export'; write_status(status_path, status)
            command(['docker', 'stop', '--time', '60', *identities], timeout=150)
            try:
                command(['rsync', '-a', '--delete', '--delay-updates', '--', str(staged_source) + '/', str(source) + '/'], timeout=900)
                command(['rsync', '-a', '--delete', '--delay-updates', '--', str(report_dir) + '/', str(metadata) + '/'], timeout=900)
            finally:
                command(['docker', 'start', *identities], timeout=120)
        status['stage'] = 'index-code-and-graph'; write_status(status_path, status)
        deadline = time.monotonic() + job.get('timeoutSeconds', 43200)
        clients = {kind: wait_ready(item[kind + 'Url'], deadline) for kind in ('code', 'graph')}
        # Native startup refreshes the new source incrementally; no database reset.
        while time.monotonic() < deadline:
            code = clients['code'].call('stats')
            graph = clients['graph'].call('get_indexing_status')
            write_status(data_root / 'refresh-state' / (config_id + '-code.json'), code)
            write_status(data_root / 'refresh-state' / (config_id + '-graph.json'), graph)
            phases = {'code': code_phase(code), 'graph': graph_phase(graph)}
            status['phases'] = phases; write_status(status_path, status)
            if set(phases.values()) == {'completed'}:
                status.update(state='succeeded', stage='completed', indexedAt=time.time(), completedAt=time.time(),
                              codeCollections=code['data']['collections'])
                write_status(status_path, status)
                return status
            time.sleep(job.get('pollSeconds', 30))
        raise RuntimeError('Native indexing exceeded its configured deadline')
    except Exception as error:
        status.update(state='failed', error=str(error), completedAt=time.time())
        write_status(status_path, status)
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host-config', required=True)
    parser.add_argument('--job-config', required=True)
    parser.add_argument('--config-id', required=True)
    parser.add_argument('--archive', required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    host = json.loads(Path(args.host_config).read_text(encoding='utf-8'))
    validate_config(host)
    job = json.loads(Path(args.job_config).read_text(encoding='utf-8'))
    with maintenance_lock(host['lockPath'], blocking=True):
        result = refresh(host, job, args.config_id, args.archive, args.sha256, args.force)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
