"""Resolve retained native recovery code; this is never live release proof."""
from __future__ import annotations

import hashlib
from pathlib import Path
import re

from .common import WorkError, digest

NAMES = ('agent-1c.core.ps1', 'agent-1c.runtime-values.ps1',
         'agent-1c.sessions.ps1', 'agent-1c.vanessa.ps1')


def resolve(coordinator, inputs):
    if not isinstance(inputs, list) or len(inputs) != len(NAMES):
        raise WorkError('NATIVE_RECOVERY_HELPER_GENERATION_REQUIRED')
    expected_root = Path(coordinator.root) / 'native-helper-generations'
    entries = {}
    generation = None
    for item in inputs:
        if (not isinstance(item, dict) or set(item) != {'path', 'sha256'} or
                not isinstance(item['path'], str) or not isinstance(item['sha256'], str) or
                not re.fullmatch('[a-f0-9]{64}', item['sha256'])):
            raise WorkError('NATIVE_RECOVERY_HELPER_INPUT_INVALID')
        path = Path(item['path'])
        candidate = path.parent.name
        if (path.name not in NAMES or path.name in entries or not path.is_absolute() or
                not re.fullmatch('[a-f0-9]{64}', candidate) or path.parent.parent != expected_root or
                (generation is not None and generation != candidate)):
            raise WorkError('NATIVE_RECOVERY_HELPER_GENERATION_REQUIRED')
        for component in (expected_root, path.parent, path):
            if component.is_symlink() or getattr(component, 'is_junction', lambda: False)():
                raise WorkError('NATIVE_RECOVERY_HELPER_ARCHIVE_REDIRECTED')
        if not path.is_file() or digest(path) != item['sha256']:
            raise WorkError('NATIVE_RECOVERY_HELPER_ARCHIVE_CHANGED')
        generation = candidate
        entries[path.name] = {'path': str(path), 'sha256': item['sha256']}
    identity = '\n'.join(name + ':' + entries[name]['sha256'] for name in NAMES)
    if hashlib.sha256(identity.encode('utf-8')).hexdigest() != generation:
        raise WorkError('NATIVE_RECOVERY_HELPER_GENERATION_CHANGED')
    return {'generation': generation, 'files': [entries[name] for name in NAMES]}
