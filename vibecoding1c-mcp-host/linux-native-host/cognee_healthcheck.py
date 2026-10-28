"""Read-only Docker healthcheck for the shared native Cognee API.

Docker owns process recovery. This probe never restarts a container, invokes an
embedding/model, fetches note content or changes a dataset.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import time
import urllib.error
import urllib.request


def probe(credential_file, principal_id, data_path='/data', *,
          request_timeout=8, min_free_bytes=2 * 1024**3,
          open_url=urllib.request.urlopen, disk_usage=shutil.disk_usage,
          clock=time.monotonic, cgroup=Path('/sys/fs/cgroup')):
    started = clock()
    status = {'status': 'unhealthy', 'api': 'unconfirmed', 'warnings': []}
    try:
        secret = json.loads(Path(credential_file).read_text(encoding='utf-8'))['apiKey']
        if not isinstance(secret, str) or not secret.strip():
            raise ValueError('Missing API key')

        def read(path):
            remaining = request_timeout - (clock() - started)
            if remaining <= 0:
                raise TimeoutError('Probe deadline')
            request = urllib.request.Request(
                'http://127.0.0.1:8000' + path,
                headers={'X-Api-Key': secret, 'Accept': 'application/json'},
                method='GET')
            with open_url(request, timeout=remaining) as response:
                # Bound diagnostic reads; originals and graph/vector searches
                # are intentionally outside the probe's contract.
                body = response.read(1024 * 1024 + 1)
                if len(body) > 1024 * 1024:
                    raise ValueError('Probe response too large')
            return json.loads(body)

        user = read('/api/v1/users/me')
        if user.get('id') != principal_id or user.get('is_superuser') is not False:
            status['reason'] = 'ordinary-principal-mismatch'
            return status
        datasets = read('/api/v1/datasets')
        if not isinstance(datasets, list):
            raise ValueError('Unexpected dataset response')
        status.update(api='available', datasetCount=len(datasets))
        status['diskFreeBytes'] = disk_usage(data_path).free
        if status['diskFreeBytes'] < min_free_bytes:
            status['reason'] = 'data-disk-low'
            return status
        if status['diskFreeBytes'] < 5 * 1024**3:
            status['warnings'].append('data-disk-reserve-under-5GiB')
        # Optional cgroup v2 telemetry. High use is a warning, never a restart
        # request: native ingestion can legitimately be busy.
        try:
            used = int((cgroup / 'memory.current').read_text().strip())
            limit = (cgroup / 'memory.max').read_text().strip()
            status['memoryCurrentBytes'] = used
            if limit != 'max':
                status['memoryLimitBytes'] = int(limit)
                if used >= int(limit) * 0.9:
                    status['warnings'].append('memory-at-least-90-percent')
        except (OSError, ValueError):
            pass
        if clock() - started > request_timeout:
            raise TimeoutError('Probe deadline')
        status['status'] = 'healthy'
    except urllib.error.HTTPError as error:
        status['reason'] = 'api-http-' + str(error.code)
    except Exception as error:
        # Exceptions/response bodies may contain credentials or source data.
        # Persist only the class, never str(error), URL headers or response body.
        status['reason'] = type(error).__name__
    finally:
        status['elapsedSeconds'] = round(clock() - started, 3)
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--credential-file', required=True)
    parser.add_argument('--principal-id', required=True)
    args = parser.parse_args()
    result = probe(args.credential_file, args.principal_id)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result['status'] == 'healthy' else 1


if __name__ == '__main__':
    raise SystemExit(main())
