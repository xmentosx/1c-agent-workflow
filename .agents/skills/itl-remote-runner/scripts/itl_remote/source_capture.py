"""Read database CF/CFE snapshots and extract them in an owned scratch infobase."""
from __future__ import annotations

import hashlib
from contextlib import ExitStack
from pathlib import Path
import shutil
import uuid

from .access import Lease
from .common import OwnedProcess, WorkError, beneath, digest, read_json, stamp, write_json


def extension_names(log, *, diagnostics=None):
    """DumpDBCfgList emits identifiers; unexpected diagnostics are never names."""
    names = []
    for line in Path(log).read_text(encoding="utf-8-sig").splitlines():
        name = line.strip()
        if not name:
            continue
        # /DisableStartupDialogs permits Designer to work without repository
        # authentication. Its startup notice is not an extension identifier.
        if name == 'Connection to the configuration repository is not established':
            if diagnostics is not None:
                diagnostics.append({'code': 'SOURCE_CAPTURE_REPOSITORY_OFFLINE', 'message': name, 'log': str(log)})
            continue
        if not name.isidentifier():
            raise WorkError("SOURCE_CAPTURE_EXTENSION_LIST_UNRECOGNIZED")
        if name in names:
            raise WorkError("SOURCE_CAPTURE_EXTENSION_LIST_DUPLICATE")
        names.append(name)
    return names


class Snapshot:
    def __init__(self, context_path, deadline):
        self.context_path = Path(context_path).resolve()
        self.context = read_json(self.context_path)
        self.deadline = deadline
        self.identifier = uuid.uuid4().hex
        self.root = beneath(self.context_path.parent, "source-snapshots/" + self.identifier)
        self.root.mkdir(parents=True)
        (self.root / "private").mkdir()
        self.result = {"schemaVersion": 1, "snapshotId": self.identifier, "jobId": self.context["jobId"],
                       "status": "running", "startedAt": stamp(), "steps": [], "artifacts": [],
                       "configurations": [], "cleanupErrors": [], "cleanupWarnings": [], "diagnostics": [],
                       "source": "database-configuration", "targetConfigurationUpdated": False}
        self.save()

    def save(self):
        write_json(self.root / "snapshot.json", self.result)

    def step(self, operation, extension=None):
        step_id = uuid.uuid4().hex
        timeout = self.deadline.remaining()
        spec = {"snapshotId": self.identifier, "stepId": step_id, "operation": operation,
                "extension": extension, "timeoutSeconds": timeout}
        spec_path = self.root / "private" / (step_id + "-spec.json")
        write_json(spec_path, spec)
        record_index = len(self.result["steps"])
        self.result["steps"].append({"stepId": step_id, "operation": operation, "status": "running",
                                     "startedAt": stamp(), "timeoutSeconds": timeout})
        self.save()
        helper = Path(__file__).resolve().parent.parent / "Invoke-SourceCaptureStep.ps1"
        try:
            process = OwnedProcess(["powershell.exe", "-NoProfile", "-File", str(helper), "-SpecPath", str(spec_path)],
                                   self.context["target"]["workspace"], self.root / (step_id + "-host.log"),
                                   {"ITL_RUN_CONTEXT": str(self.context_path)})
        except Exception:
            self.result["steps"][record_index].update(status="failed", error="SOURCE_CAPTURE_LAUNCH_FAILED")
            self.save()
            raise
        failure = None
        try:
            # The step watches the same cancellation file, then proves its own
            # process exit. Allow its bounded termination before closing the job.
            process.wait(timeout + 15, lambda: False)
        except Exception as error:
            failure = error
        finally:
            try:
                process.close()
            except Exception as error:
                self.result["cleanupErrors"].append(str(error))
        result_path = self.root / (step_id + ".json")
        if not result_path.is_file():
            self.result["cleanupErrors"].append("SOURCE_CAPTURE_STEP_EXIT_UNPROVEN")
            self.result["steps"][record_index].update(status="failed", error="SOURCE_CAPTURE_STEP_RESULT_MISSING")
            self.save()
            raise WorkError("SOURCE_CAPTURE_STEP_RESULT_MISSING") from failure
        record = read_json(result_path)
        self.result["steps"][record_index] = {"stepId": step_id, **record}
        self.result["cleanupErrors"].extend(record.get("cleanupErrors", []))
        self.save()
        if record.get("status") != "completed" or failure or self.result["cleanupErrors"]:
            raise WorkError(record.get("error", "SOURCE_CAPTURE_STEP_FAILED")) from failure
        return record

    def artifact(self, path, *, allow_empty=False):
        path = Path(path)
        checked = beneath(self.root, path.relative_to(self.root))
        if not checked.is_file() or (not allow_empty and checked.stat().st_size == 0):
            raise WorkError("SOURCE_CAPTURE_ARTIFACT_MISSING")
        self.result["artifacts"].append({"path": path.relative_to(self.root).as_posix(),
                                         "sha256": digest(path), "bytes": path.stat().st_size})

    def cleanup_scratch(self):
        marker = self.root / "private/scratch-owner.json"
        if not marker.is_file():
            if (self.root / "private/scratch").exists():
                self.result["cleanupWarnings"].append("SOURCE_CAPTURE_SCRATCH_WITHOUT_COMPLETION_MARKER")
            return
        if self.result["cleanupErrors"]:
            return
        try:
            owner = read_json(marker)
            scratch = beneath(self.root, "private/scratch")
        except (OSError, ValueError, WorkError):
            self.result["cleanupWarnings"].append("SOURCE_CAPTURE_SCRATCH_OWNER_UNREADABLE")
            return
        if (owner.get("snapshotId") != self.identifier or owner.get("jobId") != self.context["jobId"] or
                Path(owner.get("path", "")).resolve() != scratch):
            self.result["cleanupWarnings"].append("SOURCE_CAPTURE_SCRATCH_OWNER_MISMATCH")
            return
        # Both absolute ownership and containment have been verified. No target
        # database or caller-supplied recursive-delete path reaches this point.
        try:
            if scratch.exists():
                shutil.rmtree(scratch)
            marker.unlink()
        except OSError:
            self.result["cleanupWarnings"].append("SOURCE_CAPTURE_SCRATCH_RETAINED")

    def cleanup_and_release(self, lease):
        try:
            self.cleanup_scratch()
        except Exception as error:
            self.result["cleanupErrors"].append(str(error))
            raise
        finally:
            lease.release(cleanup_errors=self.result["cleanupErrors"])

    def run(self):
        proof = self.context.get("accessLease")
        try:
            if not proof:
                raise WorkError("SOURCE_CAPTURE_ACCESS_LEASE_REQUIRED")
            with ExitStack() as owner:
                lease = owner.enter_context(Lease(proof["coordinator"], [self.context["target"]["infoBase"]],
                            {"jobId": self.context["jobId"], "purpose": "source-capture"}, inherited=proof,
                            timeout=self.deadline.remaining(),
                            cancelled=lambda: bool(self.context.get("cancelPath") and Path(self.context["cancelPath"]).exists())))
                owner.callback(self.cleanup_and_release, lease)
                initial = extension_names(self.step("list-extensions")["log"], diagnostics=self.result['diagnostics'])
                self.step("dump-database")
                self.artifact(self.root / "database.cf")
                for name in initial:
                    self.step("dump-extension", name)
                    self.artifact(self.root / "extensions" / (hashlib.sha256(name.encode("utf-8")).hexdigest() + ".cfe"))
                final = extension_names(self.step("list-extensions")["log"], diagnostics=self.result['diagnostics'])
                if sorted(initial) != sorted(final):
                    raise WorkError("SOURCE_CAPTURE_EXTENSIONS_CHANGED")
                self.step("create-scratch")
                for name in [None, *initial]:
                    self.step("load-snapshot", name)
                    self.step("dump-sources", name)
                    folder = self.root / ("extension-sources/" + hashlib.sha256(name.encode("utf-8")).hexdigest() if name else "configuration")
                    self.artifact(folder / "ConfigDumpInfo.xml")
                    self.artifact(folder / "Configuration.xml")
                    # Bind later analysis to the exact exported metadata and
                    # source bytes, including legitimate empty BSL modules.
                    for path in sorted(folder.rglob('*')):
                        self.deadline.remaining()
                        if path.is_file() and path.suffix.lower() in ('.xml', '.bsl') and path not in (
                                folder / 'ConfigDumpInfo.xml', folder / 'Configuration.xml'):
                            self.artifact(path, allow_empty=path.suffix.lower() == '.bsl')
                    self.result["configurations"].append({"extensionName": name or "", "path": folder.relative_to(self.root).as_posix()})
                self.result["status"] = "captured"
        except Exception as error:
            self.result["status"] = "failed"
            self.result["error"] = str(error)
        finally:
            self.result["finishedAt"] = stamp()
            self.save()
        return {**self.result, "path": str(self.root)}
