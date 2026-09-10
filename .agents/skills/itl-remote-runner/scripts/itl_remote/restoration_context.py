"""Pinned local lifecycle context for a database snapshot, never journal secrets."""
from pathlib import Path
import re

from .common import WorkError, digest, read_json


def _path(path):
    if not isinstance(path, str) or not Path(path).is_absolute() or '..' in Path(path).parts:
        raise WorkError('RESTORATION_CONTEXT_ARTIFACT_INVALID')
    candidate = Path(path)
    for part in (candidate, *candidate.parents):
        if part.is_symlink() or getattr(part, 'is_junction', lambda: False)():
            raise WorkError('RESTORATION_CONTEXT_ARTIFACT_REDIRECTED')
    return candidate


def _file(path, expected_hash):
    if not isinstance(path, str) or not Path(path).is_absolute() or not isinstance(expected_hash, str) or not re.fullmatch('[a-f0-9]{64}', expected_hash):
        raise WorkError('RESTORATION_CONTEXT_ARTIFACT_INVALID')
    candidate = _path(path)
    if not candidate.is_file() or digest(candidate) != expected_hash:
        raise WorkError('RESTORATION_CONTEXT_ARTIFACT_CHANGED')
    return candidate


def read(coordinator, duty):
    reference = duty.get('recoveryContext')
    if (not isinstance(reference, dict) or set(reference) != {'path', 'sha256'} or
            reference.get('path') != duty['snapshotPath'] + '.recovery.json'):
        raise WorkError('RESTORATION_CONTEXT_REQUIRED')
    manifest = read_json(_file(reference['path'], reference['sha256']))
    fields = {'schemaVersion', 'kind', 'project', 'state', 'environment', 'configuration', 'source', 'platform'}
    if (not isinstance(manifest, dict) or set(manifest) not in (fields, fields | {'absentFileResources'}) or
            manifest['schemaVersion'] != 1 or manifest['kind'] != 'extension-initialization' or manifest['project'] != duty['project']):
        raise WorkError('RESTORATION_CONTEXT_BINDING_CHANGED')
    absent = manifest.get('absentFileResources', [])
    if not isinstance(absent, list) or any(not isinstance(base, dict) or set(base) != {'kind', 'path'} or
            base['kind'] != 'file' or not isinstance(base['path'], str) or not Path(base['path']).is_absolute() for base in absent):
        raise WorkError('RESTORATION_CONTEXT_ABSENT_RESOURCE_INVALID')
    if absent:
        identities = set(coordinator.resources(absent))
        if not identities.issubset(coordinator.resources(duty['resources'])) or identities.intersection(coordinator.resources([duty['infoBase']])):
            raise WorkError('RESTORATION_CONTEXT_ABSENT_RESOURCE_SCOPE_CHANGED')
    for name, suffix, fields in (
            ('state', '.state.json', {'destination', 'snapshotPath', 'sha256'}),
            ('environment', '.env', {'destination', 'snapshotPath', 'sha256', 'existed'}),
            ('configuration', '.project.json', {'snapshotPath', 'sha256'})):
        entry = manifest[name]
        if not isinstance(entry, dict) or set(entry) != fields:
            raise WorkError('RESTORATION_CONTEXT_ARTIFACT_INVALID')
        if name == 'environment':
            if type(entry['existed']) is not bool or entry['destination'] != str(Path(duty['project']) / '.dev.env'):
                raise WorkError('RESTORATION_CONTEXT_ENVIRONMENT_CHANGED')
            if not entry['existed']:
                if entry['snapshotPath'] or entry['sha256']:
                    raise WorkError('RESTORATION_CONTEXT_ARTIFACT_INVALID')
                continue
        if entry['snapshotPath'] != duty['snapshotPath'] + suffix:
            raise WorkError('RESTORATION_CONTEXT_ARTIFACT_SCOPE_CHANGED')
        _file(entry['snapshotPath'], entry['sha256'])
    state = read_json(manifest['state']['snapshotPath'])
    if not isinstance(state, dict):
        raise WorkError('RESTORATION_CONTEXT_STATE_INVALID')
    target = {'kind': state.get('infoBaseKind'), 'path': state.get('devBranchInfoBasePath')}
    if coordinator.resources([target]) != coordinator.resources([duty['infoBase']]):
        raise WorkError('RESTORATION_CONTEXT_DATABASE_CHANGED')
    state_path = _path(manifest['state']['destination'])
    safe_name = state.get('safeDevBranchName')
    if (not isinstance(safe_name, str) or not safe_name or state_path.name != safe_name + '.json' or
            not state_path.is_absolute() or state_path.parent.name != 'dev-branches' or state_path.parent.parent.name != '.agent-1c' or
            '..' in state_path.parts):
        raise WorkError('RESTORATION_CONTEXT_STATE_SCOPE_CHANGED')
    # Shared lifecycle state may live outside the worktree. The saved state
    # must still name this exact checkout, never a sibling branch.
    worktree = state.get('worktreePath')
    if not isinstance(worktree, str) or _path(worktree) != Path(duty['project']):
        raise WorkError('RESTORATION_CONTEXT_WORKTREE_CHANGED')
    source = manifest['source']
    if (not isinstance(source, dict) or set(source) != {'path', 'existed'} or type(source['existed']) is not bool or
            not isinstance(source['path'], str) or not Path(source['path']).is_absolute() or
            not Path(source['path']).is_relative_to(Path(duty['project'])) or
            Path(source['path']).parent != Path(duty['project']) / 'src' / 'cfe' or '..' in Path(source['path']).parts):
        raise WorkError('RESTORATION_CONTEXT_SOURCE_SCOPE_CHANGED')
    _path(source['path'])
    if Path(source['path']).exists() and not Path(source['path']).is_dir():
        raise WorkError('RESTORATION_CONTEXT_SOURCE_SCOPE_CHANGED')
    configuration = read_json(manifest['configuration']['snapshotPath'])
    if not isinstance(configuration, dict):
        raise WorkError('RESTORATION_CONTEXT_CONFIGURATION_INVALID')
    platform = manifest['platform']
    if not isinstance(platform, dict) or set(platform) != {'path', 'sha256'}:
        raise WorkError('RESTORATION_CONTEXT_PLATFORM_INVALID')
    executable = _file(platform['path'], platform['sha256'])
    if executable.name.casefold() != '1cv8.exe':
        raise WorkError('RESTORATION_CONTEXT_PLATFORM_INVALID')
    return manifest
