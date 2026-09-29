"""Narrow MantisBT 2.28.1 adapter. HTTP success is not a permission check."""
from __future__ import annotations

import json
from email.utils import parsedate_to_datetime
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, build_opener, HTTPRedirectHandler
import xml.etree.ElementTree as ET

from mantis_state import object_id


CONFIG_KEYS = (
    "report_bug_threshold", "update_bug_threshold", "add_bugnote_threshold",
    "bugnote_user_edit_threshold", "update_bugnote_threshold", "upload_bug_file_threshold",
    "private_bug_threshold", "private_bugnote_threshold", "change_view_status_threshold",
    "set_status_threshold", "status_enum_workflow",
    "bug_readonly_status_threshold", "update_readonly_bug_threshold", "reopen_bug_threshold",
    "bug_resolved_status_threshold", "tag_attach_threshold", "tag_create_threshold",
    "tag_detach_threshold", "tag_detach_own_threshold", "max_file_size",
    "allowed_files", "disallowed_files", "status_enum_string", "access_levels_enum_string",
    "update_bug_assign_threshold", "handle_bug_threshold",
)


class ApiError(RuntimeError):
    def __init__(self, message, status=0):
        super().__init__(message)
        self.status = status


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ApiError("Mantis redirected the request; configure its final base URL", code)


class Api:
    def __init__(self, settings):
        settings.validate()
        self.settings = settings
        self.opener = build_opener(NoRedirect())
        self.server_time = 0

    def request(self, path, method="GET", payload=None, etag=""):
        headers = {"Authorization": self.settings.api_token, "Accept": "application/json",
                   "Content-Type": "application/json", "User-Agent": "mantis-ticket-mcp/2"}
        if etag:
            headers["If-Match"] = etag
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8") if payload is not None else None
        request = Request(self.settings.base_url + "/api/rest/" + path.lstrip("/"), body, headers, method=method)
        try:
            with self.opener.open(request, timeout=self.settings.timeout_seconds) as response:
                raw = response.read()
                if response.headers.get("Date"):
                    self.server_time = parsedate_to_datetime(response.headers["Date"]).timestamp()
                return (json.loads(raw.decode("utf-8")) if raw else {}), response.headers.get("ETag", "")
        except HTTPError as exc:
            # No remote response bodies, credentials or issue text in logs/errors.
            raise ApiError(f"Mantis {method} {path.split('?')[0]}: HTTP {exc.code}", exc.code) from exc
        except (URLError, TimeoutError, OSError, ValueError) as exc:
            raise ApiError(f"Mantis {method} request did not return a valid response") from exc

    def me(self):
        data, _ = self.request("users/me")
        user = data.get("user", data)
        if object_id(user) <= 0:
            raise ApiError("Mantis did not confirm the authenticated account")
        return user

    def projects(self):
        data, _ = self.request("projects")
        if not isinstance(data.get("projects"), list):
            raise ApiError("Incomplete Mantis project catalog")
        return data["projects"]

    def project_users(self, project_id, page, size=100, handlers_only=False):
        endpoint = "handlers" if handlers_only else "users"
        data, _ = self.request(f"projects/{int(project_id)}/{endpoint}?" + urlencode({
            "page": int(page), "page_size": int(size), "include_access_levels": 1}))
        if not isinstance(data.get("users"), list):
            raise ApiError("Incomplete Mantis project user page")
        return data["users"]

    def config(self, project_id):
        query = urlencode([("project_id", int(project_id))] + [("option[]", key) for key in CONFIG_KEYS])
        data, _ = self.request("config?" + query)
        configs = data.get("configs", [])
        if isinstance(configs, dict):
            return configs
        return {item["option"]: item.get("value") for item in configs if "option" in item}

    def context(self, project_id):
        me, projects = self.me(), self.projects()
        project = next((p for p in projects if int(p["id"]) == int(project_id)), None)
        if not project:
            raise ApiError("Project is not accessible to the service account", 403)
        return {"user": me, "project": project, "level": object_id(project.get("access_level")),
                "config": self.config(project_id)}

    def headers(self, project_id, page, size):
        data, _ = self.request("issues?" + urlencode({"project_id": int(project_id), "filter_id": "any",
            "page": page, "page_size": size, "select": "id,project,status,updated_at"}))
        if not isinstance(data.get("issues"), list):
            raise ApiError("Incomplete Mantis issue page")
        rows = data["issues"]
        if any(object_id(row.get("project")) <= 0 for row in rows):
            raise ApiError("Mantis returned an issue without its project")
        # Mantis includes subprojects. Keep the raw page length/order; consumers
        # select the exact project without mistaking a child-only page for EOF.
        return rows

    def issue(self, issue_id):
        data, etag = self.request(f"issues/{int(issue_id)}")
        issue = data.get("issue") or next(iter(data.get("issues", [])), None)
        if not issue or int(issue.get("id", 0)) != int(issue_id):
            raise ApiError("Mantis returned an incomplete issue")
        return self.normalize_lists(issue), etag

    @staticmethod
    def normalize_lists(issue):
        for name in ("notes", "attachments", "files", "tags", "custom_fields"):
            issue[name] = issue.get(name) or []
        for note in issue["notes"]:
            for name in ("attachments", "files"):
                note[name] = note.get(name) or []
        return issue

    def initial_page(self, project_id, page, size):
        data, _ = self.request("issues?" + urlencode({"project_id": int(project_id), "filter_id": "any", "page": page, "page_size": size}))
        rows = data.get("issues")
        if not isinstance(rows, list) or any(object_id(r.get("project")) <= 0 for r in rows):
            raise ApiError("Incomplete initial page or missing issue project")
        context = self.context(project_id)
        result = []
        for row in rows:
            if object_id(row["project"]) != int(project_id):
                # Each accessible project has its own import and ACL context.
                # A child row is neither a parent issue nor a revocation proof.
                result.append({"skipped_id": int(row["id"]), "updated_at": row["updated_at"]})
                continue
            try:
                result.append({"issue": self.filter_visible(self.normalize_lists(row), context)})
            except ApiError as exc:
                if exc.status != 403:
                    raise
                result.append({"denied_id": int(row["id"]), "updated_at": row["updated_at"]})
        return result

    def visible_issue(self, issue_id):
        issue, etag = self.issue(issue_id)
        context = self.context(object_id(issue["project"]))
        return self.filter_visible(issue, context), etag

    @staticmethod
    def filter_visible(issue, context):
        config, level = context["config"], context["level"]
        user_id = object_id(context["user"])
        if object_id(issue.get("view_state")) == 50 and object_id(issue.get("reporter")) != user_id and level < int(config.get("private_bug_threshold", 10**6)):
            raise ApiError("Private issue is not accessible to this account", 403)
        hidden_files = set()
        notes = []
        for note in issue.get("notes", []):
            if object_id(note.get("view_state")) == 50 and object_id(note.get("reporter")) != user_id and level < int(config.get("private_bugnote_threshold", 10**6)):
                hidden_files.update(int(f["id"]) for f in note.get("attachments", []) + note.get("files", []))
            else:
                notes.append(note)
        issue["notes"] = notes
        visible_notes = {int(n["id"]) for n in notes}
        for name in ("attachments", "files"):
            issue[name] = [f for f in issue.get(name, []) if int(f["id"]) not in hidden_files and
                           (not object_id(f.get("bugnote_id") or f.get("note_id")) or
                            object_id(f.get("bugnote_id") or f.get("note_id")) in visible_notes)]
        return issue

    def confirm_absence(self, issue_id, error):
        if not isinstance(error, ApiError) or error.status not in (403, 404):
            return False
        self.me()  # A broken credential/session is not a deletion proof.
        try:
            self.visible_issue(issue_id)
        except ApiError as second:
            return second.status in (403, 404)
        return False

    def soap(self, method, fields):
        envelope = ET.Element("{http://schemas.xmlsoap.org/soap/envelope/}Envelope")
        body = ET.SubElement(envelope, "{http://schemas.xmlsoap.org/soap/envelope/}Body")
        call = ET.SubElement(body, "{http://futureware.biz/mantisconnect}" + method)
        fields = {"username": self.me().get("name", ""), "password": self.settings.api_token, **fields}
        def add(parent, name, value):
            node = ET.SubElement(parent, name)
            if isinstance(value, dict):
                for k, v in value.items():
                    add(node, k, v)
            else:
                node.text = str(value)
        for key, value in fields.items():
            add(call, key, value)
        request = Request(self.settings.base_url + "/api/soap/mantisconnect.php",
            ET.tostring(envelope, encoding="utf-8", xml_declaration=True),
            {"Content-Type": "text/xml; charset=utf-8", "SOAPAction": method}, method="POST")
        try:
            with self.opener.open(request, timeout=self.settings.timeout_seconds) as response:
                root = ET.fromstring(response.read())
        except (HTTPError, URLError, TimeoutError, OSError, ET.ParseError) as exc:
            raise ApiError(f"Mantis SOAP {method} did not return a valid response") from exc
        def local(node):
            return node.tag.split("}")[-1]
        if any(local(n) == "Fault" for n in root.iter()):
            raise ApiError(f"Mantis SOAP {method} returned a fault")
        def parse(node):
            children = list(node)
            if not children:
                return node.text or ""
            if all(local(c) == "item" for c in children):
                return [parse(c) for c in children]
            return {local(c): parse(c) for c in children}
        value = next((n for n in root.iter() if local(n) == "return"), None)
        if value is None:
            raise ApiError(f"Mantis SOAP {method} has no return value")
        return parse(value)

    def metadata(self, project_id):
        context = self.context(project_id)
        fields = self.soap("mc_project_get_custom_fields", {"project_id": int(project_id)})
        project, _ = self.request(f"projects/{int(project_id)}")
        return {**context, "definition": project, "custom_fields": fields if isinstance(fields, list) else []}

    def tags(self):
        data = self.soap("mc_tag_get_all", {"page_number": 1, "per_page": 10000})
        if not isinstance(data, dict) or int(data.get("total_results", 0)) > 10000:
            raise ApiError("Incomplete tag catalog; increase the bounded catalog page support")
        return data.get("results", []) or []
