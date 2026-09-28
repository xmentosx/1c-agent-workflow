"""One owner for write permission checks, dispatch, journal and reconciliation."""
from __future__ import annotations

import base64
import json
import re
import threading
import time

from mantis_api import ApiError
from mantis_state import digest, encode, object_id, timestamp


ACTIONS = {"create_issue", "update_issue", "add_comment", "update_comment", "upload_file", "attach_tag", "detach_tag"}
ISSUE_FIELDS = {"summary", "description", "steps_to_reproduce", "additional_information", "category", "status",
                "priority", "severity", "reproducibility", "resolution", "view_state", "handler", "version", "build",
                "platform", "os", "os_build", "target_version", "fixed_in_version", "due_date", "custom_fields"}


def require_level(context, key, threshold=None):
    value = context["config"].get(key) if threshold is None else threshold
    if value is None:
        raise ValueError(f"Permission {key} is not confirmed; fetch the project's effective configuration")
    level = context["level"]
    allowed = level in [int(v) for v in value] if isinstance(value, list) else level >= int(value)
    if not allowed:
        raise PermissionError(f"Service account project level {level} does not satisfy {key}={value}")


def signature(text, actor, operation, step):
    marker = f"через MCP, инициатор {actor}; операция {operation}:{step}"
    return text if text.rstrip().endswith(marker) else text.rstrip() + "\n\n" + marker


def fields_match(actual, desired):
    """Compare requested values only, while retaining server-assigned metadata."""
    if isinstance(desired, dict):
        return isinstance(actual, dict) and all(fields_match(actual.get(k), v) for k, v in desired.items())
    if isinstance(desired, list):
        return isinstance(actual, list) and all(any(fields_match(a, d) for a in actual) for d in desired)
    return actual == desired or (actual is not None and str(actual) == str(desired))


class Writer:
    def __init__(self, index, enabled_actions=(), enabled_projects=()):
        self.index, self.state, self.api = index, index.state, index.api
        # Qualification is configured by the operator per action, never inferred
        # from a successful HTTP response on a vulnerable server version.
        self.enabled = set(enabled_actions) & ACTIONS
        self.enabled_projects = {int(project) for project in enabled_projects}
        self.lock = threading.Lock()  # Serializes all writes of this owner (and each issue).

    def status(self, operation_id):
        row = self.state.one("SELECT * FROM operations WHERE id=?", (operation_id,))
        if not row:
            raise ValueError("Unknown operation ID")
        return {k: json.loads(v) if k == "steps" else v for k, v in row.items() if k not in {"payload", "payload_hash"}}

    def save(self, operation, steps, status, issue_id=0):
        self.state.run("UPDATE operations SET steps=?,status=?,updated=?,issue_id=CASE WHEN ?>0 THEN ? ELSE issue_id END WHERE id=? AND status<>'access_removed'",
                       (encode(steps), status, self.state.clock(), issue_id, issue_id, operation))

    def cancel(self, operation_id, actor):
        self.state.run("UPDATE operations SET status='cancel_requested',cancel_requested=1,updated=? WHERE id=? AND status NOT IN ('succeeded','access_removed','cancelled')",
                       (self.state.clock(), operation_id))
        self.state.audit(actor, "cancel", operation_id, "requested")
        return self.status(operation_id)

    def prepare(self, operation_id, actor, steps):
        if not re.fullmatch(r"[A-Za-z0-9_-]{8,100}", operation_id):
            raise ValueError("Use a stable operation_id (8–100 letters, digits, _ or -) for every retry")
        if not actor.strip() or len(actor) > 120 or any(c in actor for c in "\r\n"):
            raise ValueError("A single-line initiator name/login from the client profile is required")
        if not isinstance(steps, list) or not 1 <= len(steps) <= 16:
            raise ValueError("Provide 1–16 concrete steps; drafting does not call execute_write")
        intent_hash = digest([actor, steps])
        existing = self.state.one("SELECT * FROM operations WHERE id=?", (operation_id,))
        if existing:
            if existing["payload_hash"] != intent_hash:
                raise ValueError("operation_id already belongs to another payload or initiator")
            return
        prepared = json.loads(encode(steps))
        targets = {int(s.get("issue_id") or 0) for s in prepared} - {0}
        creates = [i for i, s in enumerate(prepared) if s.get("action") == "create_issue"]
        if len(targets) > 1 or (creates and (creates != [0] or targets)):
            raise ValueError("A composite operation owns one issue: create first, or supply one existing issue_id")
        for number, step in enumerate(prepared):
            if step.get("action") not in ACTIONS:
                raise ValueError("Unsupported write action; call mantis_metadata")
            unexpected = set(step) - {"action", "issue_id", "project_id", "note_id", "fields", "expected_version", "file", "tag_id"}
            if unexpected:
                raise ValueError("Unknown step fields: " + ", ".join(sorted(unexpected)))
            fields = step.setdefault("fields", {})
            if not isinstance(fields, dict):
                raise ValueError("fields must be an object")
            for key in ("description", "steps_to_reproduce", "additional_information", "text"):
                if key in fields:
                    fields[key] = signature(str(fields[key]), actor, operation_id, number)
            if step["action"] == "create_issue" and "description" not in fields:
                raise ValueError("create_issue requires description and project-specific required fields")
        issue_id = int(prepared[0].get("issue_id") or 0)
        project_id = int(prepared[0].get("project_id") or 0)
        with self.state.transaction():
            self.state.run("INSERT INTO operations(id,actor,issue_id,project_id,payload_hash,payload,status,steps,created,updated) VALUES(?,?,?,?,?,?,?,?,?,?)",
                           (operation_id, actor, issue_id, project_id, intent_hash, encode(prepared), "pending",
                            encode([{"status": "pending"} for _ in prepared]), self.state.clock(), self.state.clock()))
        self.state.audit(actor, "write", operation_id, "prepared")

    def validate(self, step, issue):
        action, fields = step["action"], step.get("fields", {})
        if action not in self.enabled:
            raise PermissionError(f"{action} is not qualified/enabled on this Mantis deployment; enable it only after the documented test-contour checks")
        project_id = int(step.get("project_id") or object_id((issue or {}).get("project")))
        if project_id not in self.enabled_projects:
            raise PermissionError(f"Project {project_id} is not qualified for writes; qualify its configured actions and add its ID to MANTIS_WRITE_PROJECT_IDS")
        if issue and step.get("project_id") and object_id(issue["project"]) != project_id:
            raise ValueError("Issue does not belong to the requested project")
        context = self.api.context(project_id)
        if context["level"] < 25:
            raise PermissionError("Mantis write access requires at least reporter level in this project")
        config = context["config"]
        if issue and object_id(issue.get("status")) >= int(config.get("bug_readonly_status_threshold", 0)):
            require_level(context, "update_readonly_bug_threshold")
        if action in {"create_issue", "update_issue"}:
            require_level(context, "report_bug_threshold" if action == "create_issue" else "update_bug_threshold")
            if set(fields) - ISSUE_FIELDS:
                raise ValueError("Unsupported issue fields: " + ", ".join(sorted(set(fields) - ISSUE_FIELDS)))
            if not fields or (action == "create_issue" and not fields.get("summary")):
                raise ValueError("Issue fields and a creation summary are required")
            if "status" in fields:
                status = object_id(fields["status"])
                thresholds = config.get("set_status_threshold")
                if not isinstance(thresholds, dict) or str(status) not in thresholds:
                    raise ValueError("Requested status threshold is unconfirmed")
                require_level(context, "set_status_threshold", thresholds[str(status)])
                workflow = config.get("status_enum_workflow")
                old = object_id((issue or {}).get("status"))
                if issue and workflow:
                    permitted = workflow.get(str(old)) if isinstance(workflow, dict) else None
                    if permitted is None or str(status) not in re.findall(r"(?:^|,)(\d+):", str(permitted)):
                        raise PermissionError("Requested status transition is not confirmed by project workflow")
                if issue and old >= int(config.get("bug_resolved_status_threshold", 80)) and status < int(config.get("bug_resolved_status_threshold", 80)):
                    require_level(context, "reopen_bug_threshold")
            if "view_state" in fields:
                require_level(context, "change_view_status_threshold")
                if object_id(fields["view_state"]) == 50:
                    require_level(context, "private_bug_threshold")
            if "handler" in fields:
                require_level(context, "update_bug_assign_threshold")
            metadata = self.api.metadata(project_id)
            if "custom_fields" in fields and not fields["custom_fields"]:
                raise ValueError("Specify each custom field to clear with its ID and empty value; an empty list does not clear server fields")
            definitions = {object_id(f.get("field")): f for f in metadata["custom_fields"]}
            values = {object_id(f["field"]): f["value"] for f in fields.get("custom_fields", [])}
            required = "require_report" if action == "create_issue" else "require_update"
            if "status" in fields:
                status = object_id(fields["status"])
                required = "require_closed" if status >= int(config.get("bug_readonly_status_threshold", 90)) else "require_resolved" if status >= int(config.get("bug_resolved_status_threshold", 80)) else required
            existing = {object_id(f["field"]): f["value"] for f in (issue or {}).get("custom_fields", [])}
            for field_id, definition in definitions.items():
                value = values.get(field_id, existing.get(field_id))
                if str(definition.get(required, "0")).lower() in {"1", "true"} and value in (None, ""):
                    raise ValueError(f"Required custom field {field_id} is missing")
            for field_id, value in values.items():
                definition = definitions.get(field_id)
                if not definition:
                    raise ValueError(f"Unknown project custom field {field_id}")
                require_level(context, "custom_field_write", definition.get("access_level_rw"))
                text = str(value)
                minimum, maximum = int(definition.get("length_min", 0)), int(definition.get("length_max", 0))
                if len(text) < minimum or (maximum and len(text) > maximum):
                    raise ValueError(f"Custom field {field_id} length constraint failed")
                possible = str(definition.get("possible_values") or "")
                if possible and (possible.startswith("=") or any(v not in possible.split("|") for v in text.split("|"))):
                    raise ValueError(f"Custom field {field_id} value is not confirmed by project metadata")
                expression = str(definition.get("valid_regexp") or "")
                if expression:
                    # Plain anchored character-class patterns have the same
                    # contract; advanced PCRE constructs need separate proof.
                    if "(?" in expression or re.search(r"\\[1-9KRPpX]|\(\*", expression):
                        raise ValueError(f"Custom field {field_id} uses an unqualified PCRE construct")
                    try:
                        valid = re.search(expression, text, re.ASCII)
                    except re.error as exc:
                        raise ValueError(f"Custom field {field_id} regexp is not supported") from exc
                    if not valid:
                        raise ValueError(f"Custom field {field_id} regexp constraint failed")
        elif action in {"add_comment", "update_comment"}:
            allowed = {"text", "view_state", "files"} if action == "add_comment" else {"text", "view_state"}
            if set(fields) - allowed or not fields.get("text"):
                raise ValueError("Comment accepts text, view_state, and files only when creating the comment")
            if action == "add_comment":
                require_level(context, "add_bugnote_threshold")
            else:
                note = next((n for n in issue.get("notes", []) if int(n["id"]) == int(step.get("note_id", 0))), None)
                if not note:
                    raise ValueError("Comment is not visible in this issue")
                own = object_id(note.get("reporter")) == object_id(context["user"])
                require_level(context, "bugnote_user_edit_threshold" if own else "update_bugnote_threshold")
            if "view_state" in fields:
                require_level(context, "change_view_status_threshold")
                if object_id(fields["view_state"]) == 50:
                    require_level(context, "private_bugnote_threshold")
            if fields.get("files"):
                if not isinstance(fields["files"], list) or len(fields["files"]) > 8:
                    raise ValueError("A new comment accepts at most 8 files")
                for file in fields["files"]:
                    self.validate({"action": "upload_file", "file": file}, issue)
        elif action == "upload_file":
            require_level(context, "upload_bug_file_threshold")
            if step.get("note_id"):
                raise ValueError("Attaching to an existing comment is unsupported; choose an issue attachment explicitly")
            file = step.get("file", {})
            if not file.get("name") or not file.get("content") or set(file) - {"name", "content", "type"}:
                raise ValueError("file needs name and base64 content (optional type)")
            content = base64.b64decode(file["content"], validate=True)
            if len(content) > min(self.api.settings.max_attachment_bytes, int(config.get("max_file_size", 0))):
                raise ValueError("Attachment exceeds the confirmed size limit")
            extension = file["name"].rsplit(".", 1)[-1].lower()
            allowed = str(config.get("allowed_files") or "").lower().split(",")
            denied = str(config.get("disallowed_files") or "").lower().split(",")
            if extension in denied or (allowed != [""] and extension not in allowed):
                raise ValueError("Attachment extension is forbidden by the project")
        elif action == "attach_tag":
            require_level(context, "tag_attach_threshold")
            if int(step.get("tag_id", 0)) <= 0:
                raise ValueError("Choose a known tag ID from metadata")
        elif action == "detach_tag":
            require_level(context, "tag_detach_threshold")
        return context

    def dispatch(self, step, issue_id, etag):
        action, fields = step["action"], step.get("fields", {})
        if action == "create_issue":
            return self.api.request("issues", "POST", {**fields, "project": {"id": int(step["project_id"])}})[0]
        if action == "update_issue":
            return self.api.request(f"issues/{issue_id}", "PATCH", fields, etag)[0]
        if action == "add_comment":
            return self.api.request(f"issues/{issue_id}/notes", "POST", fields)[0]
        if action == "update_comment":
            return self.api.soap("mc_issue_note_update", {"note": {"id": int(step["note_id"]), **fields}})
        if action == "upload_file":
            return self.api.request(f"issues/{issue_id}/files", "POST", {"files": [step["file"]]})[0]
        if action == "attach_tag":
            return self.api.request(f"issues/{issue_id}/tags", "POST", {"tags": [{"id": int(step["tag_id"])}]})[0]
        return self.api.request(f"issues/{issue_id}/tags/{int(step['tag_id'])}", "DELETE")[0]

    def reconcile(self, step, record, issue_id):
        action, fields = step["action"], step.get("fields", {})
        if action == "create_issue" and not issue_id:
            candidates = []
            for header in self.api.headers(int(step["project_id"]), 1, 100):
                issue, _ = self.api.visible_issue(int(header["id"]))
                if fields_match(issue, fields) and object_id(issue.get("reporter")) == record.get("user_id"):
                    candidates.append(int(issue["id"]))
            return {"issue_id": candidates[0]} if len(candidates) == 1 else None
        issue, _, _ = self.index.refresh(issue_id, allow_cache=False)
        if action in {"create_issue", "update_issue"}:
            return {"issue_id": issue_id} if fields_match(issue, fields) else None
        if action in {"add_comment", "update_comment"}:
            note_fields = {k: v for k, v in fields.items() if k != "files"}
            candidates = [n for n in issue.get("notes", []) if fields_match(n, note_fields) and
                          (action != "update_comment" or int(n["id"]) == int(step["note_id"])) and
                          (action != "add_comment" or object_id(n.get("reporter")) == record.get("user_id")) and
                          (not record.get("resolved_server_id") or int(n["id"]) == record["resolved_server_id"])]
            record["candidates"] = [int(n["id"]) for n in candidates]
            if len(candidates) != 1:
                return None
            note = candidates[0]
            result = {"issue_id": issue_id, "note_id": int(note["id"])}
            confirmed_files = []
            for desired in fields.get("files", []):
                matches = []
                for file in note.get("attachments", []) + note.get("files", []):
                    if (file.get("filename") or file.get("name")) != desired["name"]:
                        continue
                    data, _ = self.api.request(f"issues/{issue_id}/files/{int(file['id'])}")
                    if any(int(f["id"]) == int(file["id"]) and base64.b64decode(f.get("content", "")) == base64.b64decode(desired["content"]) for f in data.get("files", [])):
                        matches.append(int(file["id"]))
                if len(matches) != 1:
                    record["confirmed_note_id"] = int(note["id"])
                    record["continuation"] = "Comment exists; one attachment is unconfirmed. Reconcile it, or explicitly choose an issue attachment/new comment. Existing-comment upload is unsupported."
                    return None
                confirmed_files.extend(matches)
            if confirmed_files:
                result["file_ids"] = confirmed_files
            return result
        if action == "upload_file":
            files = issue.get("attachments", []) + issue.get("files", [])
            candidates = {int(f["id"]): f for f in files if (f.get("filename") or f.get("name")) == step["file"]["name"] and
                          int(f["id"]) not in record.get("before_files", [])}
            matches = []
            for file_id in candidates:
                data, _ = self.api.request(f"issues/{issue_id}/files/{file_id}")
                for file in data.get("files", []):
                    if int(file["id"]) == file_id and base64.b64decode(file.get("content", "")) == base64.b64decode(step["file"]["content"]):
                        matches.append(file_id)
            record["candidates"] = matches
            if record.get("resolved_server_id"):
                matches = [fid for fid in matches if fid == record["resolved_server_id"]]
            return {"issue_id": issue_id, "file_id": matches[0]} if len(matches) == 1 else None
        attached = int(step["tag_id"]) in {object_id(t) for t in issue.get("tags", [])}
        return {"issue_id": issue_id, "tag_id": int(step["tag_id"])} if attached == (action == "attach_tag") else None

    def execute(self, operation_id, actor, steps):
        if not self.lock.acquire(timeout=1):
            return {"status": "busy", "continuation": "Retry the same operation_id; another Mantis write is finishing"}
        try:
            self.prepare(operation_id, actor, steps)
            operation = self.state.one("SELECT * FROM operations WHERE id=?", (operation_id,))
            if operation["status"] in {"succeeded", "cancelled", "access_removed"}:
                return self.status(operation_id)
            prepared, records = json.loads(operation["payload"]), json.loads(operation["steps"])
            issue_id = operation["issue_id"]
            deadline = time.monotonic() + 90
            for number, (step, record) in enumerate(zip(prepared, records)):
                issue_id = int(step.get("issue_id") or issue_id)
                if record["status"] == "succeeded":
                    issue_id = record.get("result", {}).get("issue_id", issue_id)
                    continue
                current = self.status(operation_id)
                if current["status"] == "access_removed":
                    return current
                if current["cancel_requested"]:
                    if record["status"] in {"dispatched", "unknown"}:
                        result = self.reconcile(step, record, issue_id)
                        record.update(status="succeeded" if result else "unknown", result=result)
                    self.save(operation_id, records, "unknown" if record["status"] == "unknown" else "cancelled", issue_id)
                    return self.status(operation_id)
                if record["status"] in {"dispatched", "unknown", "partial"}:
                    try:
                        result = self.reconcile(step, record, issue_id)
                    except Exception:
                        result = None
                    if not result:
                        record.update(status="unknown", continuation="Inspect the target and resolve this step explicitly; it will not be reposted")
                        self.save(operation_id, records, "unknown", issue_id)
                        return self.status(operation_id)
                    record.update(status="succeeded", result=result)
                    issue_id = result.get("issue_id", issue_id)
                    self.save(operation_id, records, "running", issue_id)
                    continue
                if record["status"] == "conflict":
                    return self.status(operation_id)
                if time.monotonic() > deadline:
                    self.save(operation_id, records, "pending", issue_id)
                    return self.status(operation_id)
                try:
                    issue, etag = (None, "") if step["action"] == "create_issue" else self.api.visible_issue(issue_id)
                    context = self.validate(step, issue)
                    if self.status(operation_id)["cancel_requested"]:
                        self.save(operation_id, records, "cancelled", issue_id)
                        return self.status(operation_id)
                    if issue and step["action"] in {"update_issue", "update_comment"}:
                        expected = step.get("expected_version")
                        if not expected:
                            raise ValueError("An expected_version from write_operation(action=inspect) is required for editing existing content")
                        if expected not in {etag, digest(issue)}:
                            record.update(status="conflict", error="Issue changed; write_operation(action=inspect) again and create a new explicit operation")
                            self.save(operation_id, records, "conflict", issue_id)
                            return self.status(operation_id)
                    record.update(status="dispatched", user_id=object_id(context["user"]), sent_at=self.state.clock(),
                                  before_files=[int(f["id"]) for f in (issue or {}).get("attachments", [])])
                    self.save(operation_id, records, "running", issue_id)
                    self.state.run("UPDATE operations SET project_id=? WHERE id=?", (object_id(context["project"]), operation_id))
                    response = self.dispatch(step, issue_id, etag)
                    if step["action"] == "create_issue" and isinstance(response, dict):
                        created = response.get("issue") or next(iter(response.get("issues", [])), {})
                        issue_id = object_id(created)
                    if isinstance(response, dict) and response.get("note"):
                        record["server_note_id"] = object_id(response["note"])
                    # Persist server-assigned IDs before the post-read can fail.
                    self.save(operation_id, records, "running", issue_id)
                    result = self.reconcile(step, record, issue_id)
                    if not result:
                        record.update(status="partial", error="Response received, but requested fields were not confirmed; inspect the target before retry")
                        self.save(operation_id, records, "partial", issue_id)
                        return self.status(operation_id)
                    issue_id = result.get("issue_id", issue_id)
                    record.update(status="succeeded", result=result)
                    self.save(operation_id, records, "running", issue_id)
                except Exception as exc:
                    dispatched = record["status"] == "dispatched"
                    conflict = isinstance(exc, ApiError) and exc.status == 412
                    # Even HTTP errors after POST can follow a partial side effect.
                    status = "conflict" if conflict else "unknown" if dispatched else "failed"
                    record.update(status=status, error=str(exc)[:300])
                    self.save(operation_id, records, status, issue_id)
                    self.state.audit(actor, "write", operation_id, status)
                    return self.status(operation_id)
            self.save(operation_id, records, "succeeded", issue_id)
            self.state.audit(actor, "write", operation_id, "succeeded")
            return self.status(operation_id)
        finally:
            self.lock.release()

    def resolve(self, operation_id, step_number, actor, outcome, server_id=0):
        """Explicit human reconciliation, never a blind automatic retry."""
        if not self.lock.acquire(timeout=1):
            raise RuntimeError("A Mantis write is still finishing; retry resolution later")
        try:
            row = self.state.one("SELECT * FROM operations WHERE id=?", (operation_id,))
            if not row or row["status"] == "access_removed":
                raise ValueError("Operation is unavailable")
            records, prepared = json.loads(row["steps"]), json.loads(row["payload"])
            record = records[int(step_number)]
            if record["status"] not in {"unknown", "partial", "dispatched"}:
                raise ValueError("Only an unknown or partial step can be resolved")
            if outcome == "not_applied":
                if record.get("confirmed_note_id") or record.get("server_note_id") or (prepared[int(step_number)]["action"] == "create_issue" and row["issue_id"]):
                    raise ValueError("A server-assigned object is already confirmed; do not recreate it. Reconcile or cancel and explicitly request only the missing action")
                record.update(status="pending", resolution_actor=actor)
            elif outcome == "applied":
                step = prepared[int(step_number)]
                issue_id = row["issue_id"] or int(server_id)
                if server_id and step["action"] != "create_issue":
                    record["resolved_server_id"] = int(server_id)
                result = self.reconcile(step, record, issue_id)
                if not result:
                    raise ValueError("The indicated result is not confirmed by Mantis; keep the step unknown")
                record.update(status="succeeded", result=result, resolution_actor=actor)
            else:
                raise ValueError("outcome must be applied or not_applied, from an explicit user resolution")
            self.save(operation_id, records, "pending", row["issue_id"])
            self.state.audit(actor, "resolve_write", operation_id, outcome)
            return self.status(operation_id)
        finally:
            self.lock.release()
