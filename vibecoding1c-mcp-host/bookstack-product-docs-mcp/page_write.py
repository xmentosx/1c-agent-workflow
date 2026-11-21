"""Personal, preview-bound BookStack page writes. No credentials or drafts on disk."""
import difflib
import hashlib
import json
import re
import secrets
import threading
import time
from collections import OrderedDict

import httpx


def digest(value):
    data = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


class PageWriteError(ValueError):
    pass


class BookStackRejected(PageWriteError):
    """BookStack definitively refused the operation."""


def positive_id(value):
    if type(value) is not int or value <= 0:
        raise PageWriteError("A positive integer ID is required.")
    return value


class PersonalAPI:
    def __init__(self, settings, token):
        self.settings = settings
        self.token = token

    def request(self, method, resource, fields=None):
        # Only internally generated resource paths reach this boundary.
        try:
            response = httpx.request(method, self.settings.base_url + "/api/" + resource,
                                     headers={"Authorization": "Token " + self.token, "Accept": "application/json"},
                                     json=fields, follow_redirects=False, timeout=self.settings.timeout_seconds)
        except httpx.RequestError:
            raise PageWriteError("BookStack transport failed.") from None
        if not response.is_success:
            hint = {401: " Replace the saved personal token.", 403: " Check personal page permissions."}
            error = BookStackRejected if response.status_code in (400, 401, 403, 404, 422) else PageWriteError
            raise error(f"BookStack HTTP {response.status_code}.{hint.get(response.status_code, '')}")
        try:
            item = response.json()
            positive_id(item["id"])
            return item
        except (TypeError, KeyError, ValueError):
            raise PageWriteError("BookStack returned an unrecognized object.") from None


class PageWriter:
    def __init__(self, settings, matches_scope, api_factory=PersonalAPI):
        self.settings = settings
        self.matches_scope = matches_scope
        self.api_factory = api_factory
        self.receipts = OrderedDict()
        self.lock = threading.Lock()
        # Concurrent MCP edits to the same page must re-read after the preceding PUT.
        self.write_locks = [threading.Lock() for _ in range(64)]

    def read_page(self, api, page_id, selectors):
        page = api.request("GET", f"pages/{positive_id(page_id)}")
        if page["id"] != page_id or not self.matches_scope(page, selectors):
            raise PageWriteError("The page is outside this BookStack view.")
        return page

    @staticmethod
    def source(page):
        fmt = "markdown" if page.get("editor") == "markdown" else "html"
        content = page.get("markdown" if fmt == "markdown" else "raw_html")
        if not isinstance(content, str):
            raise PageWriteError("BookStack did not provide editable page source.")
        return fmt, content

    def prepare(self, api, change, selectors):
        if not isinstance(change, dict) or set(change) - {"page_id", "book_id", "chapter_id", "name", "markdown", "html"}:
            raise PageWriteError("Expected page_id for an edit or book_id/chapter_id for creation, and page fields.")
        targets = [k for k in ("page_id", "book_id", "chapter_id") if k in change]
        if len(targets) != 1:
            raise PageWriteError("Specify exactly one page, book or chapter ID.")
        target = targets[0]
        target_id = positive_id(change[target])
        fields = {k: v for k, v in change.items() if k != target}
        if not fields or any(not isinstance(v, str) or not v.strip() for v in fields.values()):
            raise PageWriteError("Supply nonempty text for the fields being changed.")
        if len(fields.get("name", "")) > 255 or {"markdown", "html"} <= fields.keys():
            raise PageWriteError("Use a title of at most 255 characters and one content format.")
        body = next((k for k in ("markdown", "html") if k in fields), None)
        page = {}
        if target == "page_id":
            page = self.read_page(api, target_id, selectors)
            book_id, chapter_id = positive_id(page["book_id"]), page.get("chapter_id") or None
        else:
            if not body or "name" not in fields:
                raise PageWriteError("A new page requires its title and full content.")
            book_id = target_id if target == "book_id" else None
            chapter_id = target_id if target == "chapter_id" else None
        chapter = {}
        if chapter_id:
            chapter = api.request("GET", f"chapters/{positive_id(chapter_id)}")
            if chapter["id"] != chapter_id or (book_id and chapter.get("book_id") != book_id):
                raise PageWriteError("Page location changed. Prepare a fresh preview.")
            book_id = positive_id(chapter["book_id"])
        location = {"id": page.get("id"), "book_id": book_id, "chapter_id": chapter_id}
        if not self.matches_scope(location, selectors):
            raise PageWriteError("The destination is outside this BookStack view.")
        book = api.request("GET", f"books/{book_id}")
        if book["id"] != book_id:
            raise PageWriteError("BookStack returned a different destination.")
        preview = dict(location, book=book["name"], chapter=chapter.get("name"),
                       title=fields.get("name", page.get("name")), operation="edit" if page else "create")
        if not page:
            preview.update(format=body, content=fields[body])
            return preview, None, "POST", "pages", change
        preview.update(previous_title=page["name"], url=self.settings.base_url + f"/link/{target_id}")
        if body:
            original_format, original = self.source(page)
            if body != original_format:
                raise PageWriteError(f"Preserve the current editor; submit {original_format} source.")
            preview.update(format=body, diff=list(difflib.unified_diff(original.splitlines(True),
                           fields[body].splitlines(True), fromfile="before", tofile="after")))
        if preview["previous_title"] == preview["title"] and not preview.get("diff"):
            raise PageWriteError("No page changes to publish.")
        revision = [page.get(k) for k in ("revision_count", "updated_at", "editor", "raw_html", "markdown")]
        return preview, revision, "PUT", f"pages/{target_id}", fields

    def run(self, change, confirmation, token, view, selectors):
        if not isinstance(token, str) or not re.fullmatch(r"[!-9;-~]+:[!-9;-~]+", token):
            raise PageWriteError("Personal credential required. Use the installed product-docs bookstack-write.ps1 helper.")
        owner = digest([token, view, self.settings.base_url, change])
        api = self.api_factory(self.settings, token)
        if not confirmation and set(change) == {"page_id"}:
            page = self.read_page(api, change["page_id"], selectors)
            fmt, content = self.source(page)
            return {"ok": True, "page_id": page["id"], "name": page["name"], fmt: content}
        if not confirmation:
            preview, revision, *_ = self.prepare(api, change, selectors)
            key = secrets.token_urlsafe(32)
            with self.lock:
                self.receipts[key] = (time.monotonic(), owner, digest([preview, revision]), None)
                while len(self.receipts) > 4096:
                    self.receipts.popitem(last=False)
            return {"ok": True, "preview": preview, "confirmation": key}

        target = next((change[k] for k in ("page_id", "chapter_id", "book_id") if k in change), None)
        with self.write_locks[positive_id(target) % len(self.write_locks)]:
            with self.lock:
                record = self.receipts.get(confirmation)
            if not record or record[1] != owner or time.monotonic() - record[0] > 3600:
                raise PageWriteError("Missing, mismatched or expired preview. Check the page before preparing again.")
            if record[3] is not None:
                return record[3]
            preview, revision, method, path, fields = self.prepare(api, change, selectors)
            if digest([preview, revision]) != record[2]:
                raise PageWriteError("The page or destination changed. Show a fresh preview and request approval.")
            unknown = {"ok": False, "error": "Write outcome unknown. Inspect the page in BookStack before another preview."}
            with self.lock:
                self.receipts[confirmation] = (*record[:3], unknown)
            try:
                saved = api.request(method, path, fields)
                if method == "PUT" and saved["id"] != target:
                    return unknown
                result = {"ok": True, "page_id": saved["id"], "url": self.settings.base_url + f"/link/{saved['id']}"}
                actor = saved.get("created_by" if method == "POST" else "updated_by")
                if isinstance(actor, dict):
                    result["author"] = {"id": actor.get("id"), "name": actor.get("name")}
            except BookStackRejected as exc:
                result = {"ok": False, "error": str(exc)}
            except PageWriteError as exc:
                result = dict(unknown, error=f"{exc} {unknown['error']}")
            with self.lock:
                self.receipts[confirmation] = (*record[:3], result)
            return result
