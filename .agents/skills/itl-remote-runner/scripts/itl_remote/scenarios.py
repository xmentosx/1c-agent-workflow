"""Project-owned starter scenario; calibration is explicitly not 1C evidence."""
from pathlib import Path
from .common import WorkError, write_json
from .jobs import job_id

WORKLOAD = '''import sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from itl_measure import context, measurement, verify
c = context()
output = Path(c["iteration"]) / "calibration.txt"
if sys.argv[2] == "action":
    with measurement():
        time.sleep(c["parameters"]["delaySeconds"])
        output.write_text("calibration-ready", encoding="utf-8")
else:
    verify([{"name": "calibration output", "passed": output.read_text(encoding="utf-8") == "calibration-ready"}])
'''

def scaffold(project, name):
    job_id(name)
    root = Path(project).resolve(strict=True)
    destination = root / "tests" / "performance" / name
    if destination.exists():
        raise WorkError("SCENARIO_ALREADY_EXISTS")
    destination.mkdir(parents=True)
    (destination / "workload.py").write_text(WORKLOAD, encoding="utf-8")
    write_json(destination / "scenario.json", {
        "schemaVersion": 1, "id": name, "adapter": "handshake",
        "readyDescription": "Calibration file is written; replace with product readiness before measuring 1C",
        "dataIdentity": "calibration-v1", "repeatable": True, "mutates": False,
        "parameters": {"delaySeconds": {"type": "number", "default": 0.1}},
        "files": ["workload.py"], "commands": {
            "action": ["{python}", "{input}/workload.py", "{runtime}", "action"],
            "verify": ["{python}", "{input}/workload.py", "{runtime}", "verify"]}})
    return {"scenario": str(destination / "scenario.json"), "kind": "calibration-not-product-evidence"}
