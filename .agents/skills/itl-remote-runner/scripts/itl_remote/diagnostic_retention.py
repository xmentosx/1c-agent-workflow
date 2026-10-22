"""Terminal measurement enrollment; the installed workflow owns deletion policy."""
from pathlib import Path
import os
import re
import uuid

from .common import beneath, capture, digest, stamp, write_json


def prepare(workspace):
    workspace = Path(workspace).resolve()
    helper = workspace / ".agents/skills/1c-workflow/scripts/agent-1c.ps1"
    if os.name != "nt" or not helper.is_file():
        return None  # Portable measurements need no installed lifecycle package.
    parent = beneath(workspace, "build/diagnostic-runtime")
    parent.mkdir(parents=True, exist_ok=True)
    # Never reuse a prior run's directory, even after interruption.
    root = parent / uuid.uuid4().hex
    root.mkdir()
    temporary = root / "native-temp"
    temporary.mkdir()
    return {"workspace": workspace, "helper": helper, "root": root, "temporary": temporary}


def complete(owner, result, run):
    if owner is None or result["cleanupErrors"]:
        return {"status": "retained", "reason": "no installed owner or process cleanup unconfirmed"}
    workspace, root = owner["workspace"], owner["root"]
    files = sorted(path.relative_to(workspace).as_posix() for path in owner["temporary"].iterdir()
                   if path.is_file() and not path.is_symlink()
                   and re.fullmatch(r"v8_[a-fA-F0-9]+_[a-fA-F0-9]+\.tmp", path.name))
    receipt = root / "completion.json"
    write_json(receipt, {"status": "completed" if result["status"] == "partial" else result["status"],
                         "cleanupConfirmed": True, "producer": "itl-performance",
                         "jobId": result["jobId"], "finishedAt": stamp(), "kind": "native-temp",
                         "resultPath": str(Path(run) / "result.json"),
                         "resultSha256": digest(Path(run) / "result.json"),
                         "disposablePaths": files, "retainedPaths": []})
    # argv remains data, including whitespace and Cyrillic. No shell interpolation.
    output = capture(["powershell.exe", "-NoProfile", "-File", str(owner["helper"]),
                      "-Action", "clean-artifacts", "-CleanupDiagnosticsOnly",
                      "-DiagnosticCompletionPath", str(receipt.relative_to(workspace)),
                      "-ProjectRoot", str(workspace)], timeout=300)
    # Keep the helper's bounded report separately from business acceptance.
    (root / "retention.log").write_text(output.decode("utf-8", errors="strict"), encoding="utf-8")
    return {"status": "completed", "enrolledCandidates": len(files),
            "receipt": str(receipt.relative_to(workspace))}
