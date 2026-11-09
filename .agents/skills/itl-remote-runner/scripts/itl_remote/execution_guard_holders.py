"""Read-only inventory of execution-guard records for one exact resource set.

Records stay diagnostic. The inventory only names holders and proves whether
the recorded supervisor process is still the one that wrote the record; the
caller owns classification and any process stop.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from .common import WorkError
from .execution_guard import (HOLDER_STATES, PROTOCOL, TERMINAL_STATES, _process_matches,
                              canonical_resources)


def inventory(root, bases, shared_bases=None):
    keys = canonical_resources(bases)
    wanted = set(keys)
    shared = set(canonical_resources(shared_bases)) if shared_bases else set()
    holders = []
    directory = Path(root) / "executions"
    if directory.is_dir():
        for path in sorted(directory.glob("*.json")):
            try:
                record = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if not isinstance(record, dict) or record.get("protocol") != PROTOCOL:
                continue
            resources = record.get("resources")
            if (not isinstance(resources, list) or record.get("state") in TERMINAL_STATES or
                    not wanted.intersection(resources)):
                continue
            holder_state = record.get("holderState")
            holders.append({
                "path": str(path),
                "executionId": str(record.get("executionId") or ""),
                "operation": str(record.get("operation") or ""),
                "state": str(record.get("state") or ""),
                "pid": record.get("pid") if isinstance(record.get("pid"), int) else 0,
                "alive": _process_matches(record.get("pid"), record.get("supervisor")),
                "resources": sorted(str(item) for item in resources),
                "touchesShared": bool(shared.intersection(resources)),
                "projectRoot": str(record.get("projectRoot") or ""),
                "holderState": holder_state if holder_state in HOLDER_STATES else "",
                "startedAt": str(record.get("startedAt") or ""),
                "heartbeatAt": str(record.get("heartbeatAt") or ""),
            })
    return {"schemaVersion": 1, "protocol": PROTOCOL, "resources": keys, "holders": holders}


def main():
    line = sys.stdin.readline()
    if line.startswith(chr(0xFEFF)):
        line = line[1:]
    try:
        request = json.loads(line)
        if request.get("schemaVersion") != 1 or not request.get("root"):
            raise WorkError("EXECUTION_GUARD_HOLDER_REQUEST_INVALID")
        result = inventory(request["root"], request.get("bases"), request.get("sharedBases"))
    except (WorkError, ValueError, TypeError, AttributeError) as error:
        sys.stdout.write(json.dumps({"error": str(error)}, ensure_ascii=True) + "\n")
        return 1
    sys.stdout.write(json.dumps(result, ensure_ascii=True, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
