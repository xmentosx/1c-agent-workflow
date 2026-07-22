from __future__ import annotations

import base64
import hashlib
import html
import io
import json
import mimetypes
import os
import re
import traceback
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, unquote, urlparse
from urllib.request import Request, urlopen


OCR_NOTICE = (
    "Черновое OCR-распознавание; если модель умеет анализировать изображения, "
    "использовать оригинал картинки как источник истины."
)

ALLOWED_STYLE_PROPERTIES = {
    "color",
    "background-color",
    "font-weight",
    "font-style",
    "font-size",
    "font-family",
    "text-decoration",
}

ALLOWED_TAGS = {
    "a",
    "b",
    "blockquote",
    "br",
    "code",
    "del",
    "em",
    "font",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "hr",
    "i",
    "li",
    "ol",
    "p",
    "pre",
    "span",
    "strong",
    "table",
    "tbody",
    "td",
    "th",
    "thead",
    "tr",
    "u",
    "ul",
}

ALLOWED_ATTRS = {
    "a": {"href", "title"},
    "font": {"color", "face", "size"},
    "span": {"style", "title"},
    "*": {"title"},
}

IMAGE_MIME_PREFIX = "image/"
TEXT_EXTENSIONS = {
    ".bsl",
    ".cfg",
    ".csv",
    ".json",
    ".log",
    ".md",
    ".sql",
    ".text",
    ".txt",
    ".xml",
    ".yaml",
    ".yml",
}


class MantisApiError(RuntimeError):
    pass


def int_env(name: str, default: int) -> int:
    value = os.environ.get(name, "").strip()
    if not value:
        return default
    try:
        return int(value)
    except ValueError:
        return default


def bool_env(name: str, default: bool) -> bool:
    value = os.environ.get(name, "").strip().lower()
    if not value:
        return default
    return value in {"1", "true", "yes", "on"}


def split_csv_env(name: str, default: Iterable[str]) -> List[str]:
    value = os.environ.get(name, "").strip()
    if not value:
        return list(default)
    return [item.strip() for item in re.split(r"[,;+]", value) if item.strip()]


@dataclass(frozen=True)
class Settings:
    base_url: str
    api_token: str
    attachment_cache_path: Path
    timeout_seconds: int = 20
    max_attachment_bytes: int = 25 * 1024 * 1024
    max_inline_text_chars: int = 16000
    ocr_enabled: bool = True
    ocr_languages: Tuple[str, ...] = ("rus", "eng")
    host: str = "0.0.0.0"
    port: int = 8000

    @classmethod
    def from_env(cls) -> "Settings":
        base_url = os.environ.get("MANTIS_BASE_URL", "").strip().rstrip("/")
        api_token = os.environ.get("MANTIS_API_TOKEN", "").strip()
        cache = Path(os.environ.get("MANTIS_ATTACHMENT_CACHE_PATH", "/data/attachments").strip())
        languages = tuple(split_csv_env("MANTIS_OCR_LANGUAGES", ("rus", "eng")))
        return cls(
            base_url=base_url,
            api_token=api_token,
            attachment_cache_path=cache,
            timeout_seconds=int_env("MANTIS_TIMEOUT_SECONDS", 20),
            max_attachment_bytes=int_env("MANTIS_MAX_ATTACHMENT_BYTES", 25 * 1024 * 1024),
            max_inline_text_chars=int_env("MANTIS_MAX_INLINE_TEXT_CHARS", 16000),
            ocr_enabled=bool_env("MANTIS_OCR_ENABLED", True),
            ocr_languages=languages,
            host=os.environ.get("MANTIS_MCP_HOST", "0.0.0.0").strip() or "0.0.0.0",
            port=int_env("MANTIS_MCP_PORT", 8000),
        )

    def validate(self) -> None:
        missing = []
        if not self.base_url:
            missing.append("MANTIS_BASE_URL")
        if not self.api_token:
            missing.append("MANTIS_API_TOKEN")
        if missing:
            raise MantisApiError("Missing required Mantis settings: " + ", ".join(missing))


class MantisClient:
    def __init__(self, settings: Settings):
        settings.validate()
        self.settings = settings

    def _url(self, path: str) -> str:
        if not path.startswith("/"):
            path = "/" + path
        return self.settings.base_url + path

    def request_json(self, path: str) -> Dict[str, Any]:
        request = Request(
            self._url(path),
            headers={
                "Accept": "application/json",
                "Authorization": self.settings.api_token,
                "User-Agent": "mantis-ticket-mcp/1.0",
            },
            method="GET",
        )
        try:
            with urlopen(request, timeout=self.settings.timeout_seconds) as response:
                raw = response.read().decode("utf-8", errors="replace")
        except HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise MantisApiError(f"Mantis REST HTTP {exc.code} for {path}: {body[:500]}") from exc
        except URLError as exc:
            raise MantisApiError(f"Mantis REST request failed for {path}: {exc.reason}") from exc

        try:
            return json.loads(raw)
        except json.JSONDecodeError as exc:
            raise MantisApiError(f"Mantis REST returned invalid JSON for {path}: {raw[:500]}") from exc

    def get_issue(self, issue_id: int) -> Dict[str, Any]:
        data = self.request_json(f"/api/rest/issues/{issue_id}")
        if isinstance(data, dict):
            if isinstance(data.get("issue"), dict):
                return data["issue"]
            issues = data.get("issues")
            if isinstance(issues, list) and issues:
                if isinstance(issues[0], dict):
                    return issues[0]
            if data.get("id"):
                return data
        raise MantisApiError(f"Mantis REST response did not contain issue {issue_id}.")

    def get_issue_file(self, issue_id: int, file_id: int) -> Dict[str, Any]:
        data = self.request_json(f"/api/rest/issues/{issue_id}/files/{file_id}")
        files = data.get("files") if isinstance(data, dict) else None
        if isinstance(files, list) and files:
            for file_entry in files:
                if int_value(file_entry.get("id")) == file_id:
                    return file_entry
            if isinstance(files[0], dict):
                return files[0]
        raise MantisApiError(f"Mantis REST response did not contain file {file_id} for issue {issue_id}.")


def int_value(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def first_non_empty(*values: Any) -> str:
    for value in values:
        text = str(value or "").strip()
        if text:
            return text
    return ""


def extract_issue_id(url_or_id: str) -> int:
    text = str(url_or_id or "").strip()
    if not text:
        raise ValueError("Mantis ticket URL or id is required.")
    if re.fullmatch(r"\d+", text):
        return int(text)

    parsed = urlparse(text)
    query = parse_qs(parsed.query)
    for key in ("id", "bug_id", "issue_id"):
        for value in query.get(key, []):
            if re.fullmatch(r"\d+", value.strip()):
                return int(value.strip())

    match = re.search(r"/issues/(\d+)(?:/|$)", parsed.path)
    if match:
        return int(match.group(1))

    numeric_segments = re.findall(r"(?:^|/)(\d+)(?:/|$)", parsed.path)
    if numeric_segments:
        return int(numeric_segments[-1])

    raise ValueError(f"Could not parse Mantis issue id from: {url_or_id}")


def truncate_text(text: str, max_chars: int) -> Tuple[str, bool]:
    if max_chars <= 0 or len(text) <= max_chars:
        return text, False
    suffix = "\n...[truncated]"
    return text[: max(0, max_chars - len(suffix))] + suffix, True


class PlainTextExtractor(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts: List[str] = []

    def handle_starttag(self, tag: str, attrs: List[Tuple[str, Optional[str]]]) -> None:
        if tag in {"br", "p", "div", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6"}:
            self._newline()
        if tag == "li":
            self.parts.append("- ")

    def handle_endtag(self, tag: str) -> None:
        if tag in {"p", "div", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6"}:
            self._newline()

    def handle_data(self, data: str) -> None:
        self.parts.append(data)

    def _newline(self) -> None:
        if self.parts and not self.parts[-1].endswith("\n"):
            self.parts.append("\n")

    def text(self) -> str:
        text = "".join(self.parts)
        lines = [re.sub(r"[ \t]+", " ", line).strip() for line in text.splitlines()]
        return "\n".join([line for line in lines if line]).strip()


def html_to_text(html_text: str) -> str:
    parser = PlainTextExtractor()
    parser.feed(html_text or "")
    return parser.text()


def sanitize_style(value: str) -> str:
    kept = []
    for part in str(value or "").split(";"):
        if ":" not in part:
            continue
        name, raw = part.split(":", 1)
        name = name.strip().lower()
        raw = raw.strip()
        if name not in ALLOWED_STYLE_PROPERTIES:
            continue
        if re.search(r"expression|javascript:|url\s*\(", raw, flags=re.IGNORECASE):
            continue
        kept.append(f"{name}: {raw}")
    return "; ".join(kept)


class FallbackHtmlSanitizer(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts: List[str] = []
        self.skip_stack: List[str] = []

    def handle_starttag(self, tag: str, attrs: List[Tuple[str, Optional[str]]]) -> None:
        tag = tag.lower()
        if tag in {"script", "style"}:
            self.skip_stack.append(tag)
            return
        if self.skip_stack or tag not in ALLOWED_TAGS:
            return
        rendered_attrs = []
        allowed = set(ALLOWED_ATTRS.get(tag, set())) | set(ALLOWED_ATTRS.get("*", set()))
        for name, value in attrs:
            name = name.lower()
            value = value or ""
            if name not in allowed:
                continue
            if name == "style":
                value = sanitize_style(value)
                if not value:
                    continue
            if name == "href" and not re.match(r"^(https?://|mailto:|#)", value, flags=re.IGNORECASE):
                continue
            rendered_attrs.append(f'{name}="{html.escape(value, quote=True)}"')
        suffix = (" " + " ".join(rendered_attrs)) if rendered_attrs else ""
        self.parts.append(f"<{tag}{suffix}>")

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if self.skip_stack:
            if self.skip_stack[-1] == tag:
                self.skip_stack.pop()
            return
        if tag in ALLOWED_TAGS and tag not in {"br", "hr"}:
            self.parts.append(f"</{tag}>")

    def handle_data(self, data: str) -> None:
        if not self.skip_stack:
            self.parts.append(html.escape(data))

    def html(self) -> str:
        return "".join(self.parts)


def sanitize_html(rendered: str) -> str:
    try:
        import bleach
        from bleach.css_sanitizer import CSSSanitizer

        attrs = {
            "a": ["href", "title"],
            "font": ["color", "face", "size"],
            "span": ["style", "title"],
            "*": ["title"],
        }
        css = CSSSanitizer(allowed_css_properties=sorted(ALLOWED_STYLE_PROPERTIES))
        return bleach.clean(
            rendered,
            tags=sorted(ALLOWED_TAGS),
            attributes=attrs,
            css_sanitizer=css,
            strip=True,
        )
    except Exception:
        sanitizer = FallbackHtmlSanitizer()
        sanitizer.feed(rendered or "")
        return sanitizer.html()


def render_markup_to_html(raw_text: str) -> str:
    text = raw_text or ""
    if not text:
        return ""
    try:
        import markdown

        rendered = markdown.markdown(text, extensions=["extra", "sane_lists", "nl2br"])
    except Exception:
        if "<" in text and ">" in text:
            rendered = text.replace("\n", "<br>\n")
        else:
            rendered = html.escape(text).replace("\n", "<br>\n")
    return sanitize_html(rendered)


def parse_style_attr(value: str) -> Dict[str, str]:
    result: Dict[str, str] = {}
    for part in str(value or "").split(";"):
        if ":" not in part:
            continue
        name, raw = part.split(":", 1)
        name = name.strip().lower()
        raw = raw.strip()
        if name not in ALLOWED_STYLE_PROPERTIES or not raw:
            continue
        key = name.replace("-", "_")
        result[key] = raw
    return result


class StyleSpanParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.text_parts: List[str] = []
        self.spans: List[Dict[str, Any]] = []
        self.stack: List[Dict[str, str]] = [{}]

    @property
    def text_offset(self) -> int:
        return len("".join(self.text_parts))

    def handle_starttag(self, tag: str, attrs: List[Tuple[str, Optional[str]]]) -> None:
        tag = tag.lower()
        current = dict(self.stack[-1])
        attrs_dict = {name.lower(): value or "" for name, value in attrs}
        if tag in {"strong", "b"}:
            current["font_weight"] = "bold"
        elif tag in {"em", "i"}:
            current["font_style"] = "italic"
        elif tag == "u":
            current["text_decoration"] = "underline"
        elif tag == "code":
            current["code"] = "true"
        elif tag == "font":
            if attrs_dict.get("color"):
                current["color"] = attrs_dict["color"]
            if attrs_dict.get("face"):
                current["font_family"] = attrs_dict["face"]
            if attrs_dict.get("size"):
                current["font_size"] = attrs_dict["size"]
        elif tag == "span":
            current.update(parse_style_attr(attrs_dict.get("style", "")))
        elif tag == "br":
            self.text_parts.append("\n")
        elif tag in {"p", "div", "li", "tr"}:
            self._soft_newline()
        self.stack.append(current)

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if len(self.stack) > 1:
            self.stack.pop()
        if tag in {"p", "div", "li", "tr"}:
            self._soft_newline()

    def handle_data(self, data: str) -> None:
        if not data:
            return
        start = self.text_offset
        self.text_parts.append(data)
        end = self.text_offset
        style = {key: value for key, value in self.stack[-1].items() if value}
        if style and start != end:
            span = {"start": start, "end": end, "text": data}
            span.update(style)
            self.spans.append(span)

    def _soft_newline(self) -> None:
        if self.text_parts and not self.text_parts[-1].endswith("\n"):
            self.text_parts.append("\n")

    def result(self) -> Tuple[str, List[Dict[str, Any]]]:
        return "".join(self.text_parts).strip(), self.spans


def extract_style_spans(rendered_html: str) -> Tuple[str, List[Dict[str, Any]]]:
    parser = StyleSpanParser()
    parser.feed(rendered_html or "")
    return parser.result()


def style_markers(span: Dict[str, Any]) -> Tuple[List[str], List[str]]:
    starts: List[str] = []
    ends: List[str] = []
    if span.get("color"):
        starts.append(f"[color={span['color']}]")
        ends.insert(0, "[/color]")
    if span.get("background_color"):
        starts.append(f"[bg={span['background_color']}]")
        ends.insert(0, "[/bg]")
    if str(span.get("font_weight", "")).lower() in {"bold", "700", "600"}:
        starts.append("[bold]")
        ends.insert(0, "[/bold]")
    if str(span.get("font_style", "")).lower() == "italic":
        starts.append("[italic]")
        ends.insert(0, "[/italic]")
    if span.get("text_decoration"):
        starts.append(f"[text-decoration={span['text_decoration']}]")
        ends.insert(0, "[/text-decoration]")
    if span.get("font_size"):
        starts.append(f"[font-size={span['font_size']}]")
        ends.insert(0, "[/font-size]")
    if span.get("font_family"):
        starts.append(f"[font={span['font_family']}]")
        ends.insert(0, "[/font]")
    if span.get("code") == "true":
        starts.append("[code]")
        ends.insert(0, "[/code]")
    return starts, ends


def annotate_text_with_styles(plain_text: str, spans: List[Dict[str, Any]]) -> str:
    if not plain_text or not spans:
        return plain_text
    parts: List[str] = []
    cursor = 0
    for span in sorted(spans, key=lambda item: (int_value(item.get("start")), int_value(item.get("end")))):
        start = max(0, min(len(plain_text), int_value(span.get("start"))))
        end = max(start, min(len(plain_text), int_value(span.get("end"))))
        if end <= cursor:
            continue
        if start > cursor:
            parts.append(plain_text[cursor:start])
        starts, ends = style_markers(span)
        parts.extend(starts)
        parts.append(plain_text[start:end])
        parts.extend(ends)
        cursor = end
    if cursor < len(plain_text):
        parts.append(plain_text[cursor:])
    return "".join(parts)


def format_text_block(raw_text: str, max_chars: int = 0) -> Dict[str, Any]:
    raw = str(raw_text or "")
    rendered = render_markup_to_html(raw)
    plain, spans = extract_style_spans(rendered)
    if not plain:
        plain = html_to_text(rendered) or raw
    truncated = False
    if max_chars > 0:
        plain, truncated = truncate_text(plain, max_chars)
    return {
        "raw_text": raw,
        "plain_text": plain,
        "rendered_html_sanitized": rendered,
        "style_spans": spans,
        "agent_annotated_text": annotate_text_with_styles(plain, spans),
        "formatting_fidelity": "mcp-rendered-from-rest",
        "truncated": truncated,
    }


def safe_filename(filename: str, default: str = "attachment") -> str:
    decoded = unquote(filename or "").strip()
    decoded = re.sub(r"[\\/:*?\"<>|\r\n]+", "_", decoded)
    decoded = decoded.strip(" .")
    if not decoded:
        decoded = default
    if len(decoded) > 160:
        stem, suffix = os.path.splitext(decoded)
        decoded = stem[: max(1, 160 - len(suffix))] + suffix
    return decoded


def attachment_resource_handle(issue_id: int, file_id: int, filename: str) -> str:
    return f"mantis://issue/{issue_id}/files/{file_id}/{quote(safe_filename(filename))}"


def decode_file_content(file_data: Dict[str, Any]) -> bytes:
    content = file_data.get("content")
    if not content:
        return b""
    try:
        return base64.b64decode(str(content), validate=False)
    except Exception as exc:
        raise MantisApiError("Attachment content was not valid base64.") from exc


def is_image(content_type: str, filename: str) -> bool:
    if content_type.lower().startswith(IMAGE_MIME_PREFIX):
        return True
    guessed, _ = mimetypes.guess_type(filename)
    return bool(guessed and guessed.lower().startswith(IMAGE_MIME_PREFIX))


def is_text_file(content_type: str, filename: str) -> bool:
    content_type = content_type.lower()
    suffix = Path(filename).suffix.lower()
    if suffix in TEXT_EXTENSIONS:
        return True
    return (
        content_type.startswith("text/")
        or content_type in {"application/json", "application/xml", "application/x-yaml"}
        or content_type.endswith("+json")
        or content_type.endswith("+xml")
    )


def decode_text_bytes(content: bytes) -> str:
    for encoding in ("utf-8-sig", "utf-8", "cp1251", "latin-1"):
        try:
            return content.decode(encoding)
        except UnicodeDecodeError:
            continue
    return content.decode("utf-8", errors="replace")


def extract_pdf_text(content: bytes) -> str:
    try:
        from pypdf import PdfReader

        reader = PdfReader(io.BytesIO(content))
        parts = []
        for page in reader.pages:
            parts.append(page.extract_text() or "")
        return "\n".join(part for part in parts if part).strip()
    except Exception:
        return ""


def extract_file_text(content: bytes, content_type: str, filename: str, max_chars: int) -> Dict[str, Any]:
    text = ""
    method = ""
    if is_text_file(content_type, filename):
        text = decode_text_bytes(content)
        method = "text-decode"
    elif content_type.lower() == "application/pdf" or Path(filename).suffix.lower() == ".pdf":
        text = extract_pdf_text(content)
        method = "pdf"
    if not text:
        return {"supported": False, "text": "", "method": ""}
    text, truncated = truncate_text(text, max_chars)
    return {"supported": True, "text": text, "method": method, "truncated": truncated}


def image_dimensions(content: bytes) -> Dict[str, int]:
    try:
        from PIL import Image

        with Image.open(io.BytesIO(content)) as image:
            return {"width": int(image.width), "height": int(image.height)}
    except Exception:
        return {}


def ocr_image(content: bytes, languages: Tuple[str, ...]) -> Dict[str, Any]:
    try:
        from PIL import Image
        import pytesseract

        with Image.open(io.BytesIO(content)) as image:
            lang = "+".join([item for item in languages if item]) or "eng"
            text = pytesseract.image_to_string(image, lang=lang)
            return {
                "enabled": True,
                "notice": OCR_NOTICE,
                "text": text.strip(),
                "languages": list(languages),
                "error": "",
            }
    except Exception as exc:
        return {
            "enabled": True,
            "notice": OCR_NOTICE,
            "text": "",
            "languages": list(languages),
            "error": str(exc),
        }


def normalize_user(user: Any) -> Dict[str, Any]:
    if not isinstance(user, dict):
        return {}
    return {
        "id": user.get("id"),
        "name": user.get("name", ""),
        "real_name": user.get("real_name", ""),
        "email": user.get("email", ""),
    }


def enum_name(value: Any) -> str:
    if isinstance(value, dict):
        return first_non_empty(value.get("label"), value.get("name"), value.get("id"))
    return str(value or "")


class MantisTicketService:
    def __init__(self, settings: Settings, client: Optional[MantisClient] = None):
        self.settings = settings
        self.client = client or MantisClient(settings)
        self.settings.attachment_cache_path.mkdir(parents=True, exist_ok=True)

    def read_ticket(
        self,
        url_or_id: str,
        include_comments: bool = True,
        include_attachments: bool = True,
        image_ocr: bool = True,
    ) -> Dict[str, Any]:
        issue_id = extract_issue_id(url_or_id)
        issue = self.client.get_issue(issue_id)
        normalized = self.normalize_issue(issue, issue_id)

        if include_comments:
            notes = [self.normalize_note(issue_id, note) for note in self.as_list(issue.get("notes"))]
            notes.sort(key=lambda note: (str(note.get("created_at") or ""), int_value(note.get("id"))))
        else:
            notes = []

        issue_attachments = []
        if include_attachments:
            for attachment in self.as_list(issue.get("attachments")) + self.as_list(issue.get("files")):
                issue_attachments.append(
                    self.process_attachment(issue_id, attachment, scope="issue", note_id=0, image_ocr=image_ocr)
                )
            for note in notes:
                note_attachments = []
                for attachment in self.as_list(note.get("raw_attachments")):
                    note_attachments.append(
                        self.process_attachment(
                            issue_id,
                            attachment,
                            scope="note",
                            note_id=int_value(note.get("id")),
                            image_ocr=image_ocr,
                        )
                    )
                note["attachments"] = note_attachments
                note.pop("raw_attachments", None)

        normalized["notes"] = notes
        normalized["comments"] = notes
        normalized["attachments"] = issue_attachments
        normalized["agent_context_markdown"] = self.build_agent_context(normalized)
        return {"ok": True, "ticket": normalized}

    def get_attachment(self, issue_id: int, file_id: int, include_content: bool = True) -> Dict[str, Any]:
        data = self.client.get_issue_file(int(issue_id), int(file_id))
        meta = self.normalize_attachment_meta(int(issue_id), data, scope="unknown", note_id=0)
        content = decode_file_content(data)
        if content:
            meta.update(self.cache_attachment(int(issue_id), int(file_id), meta["filename"], content))
            meta["sha256"] = hashlib.sha256(content).hexdigest()
            meta["size"] = len(content)
        if include_content:
            meta["content_base64"] = base64.b64encode(content).decode("ascii") if content else ""
        return {"ok": True, "attachment": meta}

    def normalize_issue(self, issue: Dict[str, Any], issue_id: int) -> Dict[str, Any]:
        description = format_text_block(
            str(issue.get("description") or ""),
            max_chars=self.settings.max_inline_text_chars,
        )
        steps = format_text_block(
            str(issue.get("steps_to_reproduce") or ""),
            max_chars=self.settings.max_inline_text_chars,
        )
        additional = format_text_block(
            str(issue.get("additional_information") or ""),
            max_chars=self.settings.max_inline_text_chars,
        )
        return {
            "id": int_value(issue.get("id"), issue_id),
            "url": f"{self.settings.base_url}/view.php?id={int_value(issue.get('id'), issue_id)}",
            "summary": str(issue.get("summary") or ""),
            "project": issue.get("project", {}),
            "category": issue.get("category", {}),
            "status": issue.get("status", {}),
            "status_name": enum_name(issue.get("status")),
            "priority": issue.get("priority", {}),
            "severity": issue.get("severity", {}),
            "reproducibility": issue.get("reproducibility", {}),
            "handler": normalize_user(issue.get("handler")),
            "reporter": normalize_user(issue.get("reporter")),
            "created_at": issue.get("created_at", ""),
            "updated_at": issue.get("updated_at", ""),
            "description": description,
            "steps_to_reproduce": steps,
            "additional_information": additional,
            "tags": self.as_list(issue.get("tags")),
            "relationships": self.as_list(issue.get("relationships")),
            "custom_fields": self.as_list(issue.get("custom_fields")),
            "view_state": issue.get("view_state", {}),
        }

    def normalize_note(self, issue_id: int, note: Any) -> Dict[str, Any]:
        note = note if isinstance(note, dict) else {}
        formatted = format_text_block(
            str(note.get("text") or ""),
            max_chars=self.settings.max_inline_text_chars,
        )
        return {
            "id": int_value(note.get("id")),
            "issue_id": issue_id,
            "type": note.get("type", "note"),
            "reporter": normalize_user(note.get("reporter")),
            "created_at": note.get("created_at", ""),
            "updated_at": note.get("updated_at", ""),
            "view_state": note.get("view_state", {}),
            "time_tracking": note.get("time_tracking", {}),
            "raw_text": formatted["raw_text"],
            "plain_text": formatted["plain_text"],
            "rendered_html_sanitized": formatted["rendered_html_sanitized"],
            "style_spans": formatted["style_spans"],
            "agent_annotated_text": formatted["agent_annotated_text"],
            "formatting_fidelity": formatted["formatting_fidelity"],
            "truncated": formatted["truncated"],
            "text": formatted,
            "raw_attachments": self.as_list(note.get("attachments")),
            "attachments": [],
        }

    def process_attachment(
        self,
        issue_id: int,
        attachment: Any,
        scope: str,
        note_id: int,
        image_ocr: bool,
    ) -> Dict[str, Any]:
        attachment = attachment if isinstance(attachment, dict) else {}
        meta = self.normalize_attachment_meta(issue_id, attachment, scope=scope, note_id=note_id)
        file_id = int_value(meta.get("id"))
        if file_id <= 0:
            return meta

        declared_size = int_value(meta.get("size"))
        if declared_size > self.settings.max_attachment_bytes:
            meta["download_skipped"] = True
            meta["download_skip_reason"] = "declared size exceeds MANTIS_MAX_ATTACHMENT_BYTES"
            return meta

        try:
            file_data = self.client.get_issue_file(issue_id, file_id)
            content = decode_file_content(file_data)
        except Exception as exc:
            meta["download_error"] = str(exc)
            return meta

        if not content:
            return meta

        meta.update(self.cache_attachment(issue_id, file_id, meta["filename"], content))
        meta["sha256"] = hashlib.sha256(content).hexdigest()
        meta["size"] = len(content)
        content_type = first_non_empty(meta.get("content_type"), file_data.get("content_type"), "")
        if content_type:
            meta["content_type"] = content_type

        if is_image(meta.get("content_type", ""), meta["filename"]):
            meta["image"] = {
                "original_available": True,
                "original_is_source_of_truth": True,
                "dimensions": image_dimensions(content),
                "ocr": (
                    ocr_image(content, self.settings.ocr_languages)
                    if image_ocr and self.settings.ocr_enabled
                    else {
                        "enabled": False,
                        "notice": OCR_NOTICE,
                        "text": "",
                        "languages": list(self.settings.ocr_languages),
                        "error": "",
                    }
                ),
            }
        else:
            meta["extracted_text"] = extract_file_text(
                content,
                meta.get("content_type", ""),
                meta["filename"],
                self.settings.max_inline_text_chars,
            )
        return meta

    def normalize_attachment_meta(self, issue_id: int, attachment: Dict[str, Any], scope: str, note_id: int) -> Dict[str, Any]:
        file_id = int_value(attachment.get("id"))
        filename = safe_filename(first_non_empty(attachment.get("filename"), attachment.get("name"), f"file-{file_id}"))
        content_type = first_non_empty(
            attachment.get("content_type"),
            attachment.get("file_type"),
            mimetypes.guess_type(filename)[0] or "",
        )
        return {
            "id": file_id,
            "issue_id": issue_id,
            "scope": scope,
            "note_id": note_id,
            "filename": filename,
            "content_type": content_type,
            "size": int_value(attachment.get("size")),
            "reporter": normalize_user(attachment.get("reporter")),
            "created_at": attachment.get("created_at", ""),
            "resource_handle": attachment_resource_handle(issue_id, file_id, filename),
            "original_available": file_id > 0,
            "get_attachment": {"issue_id": issue_id, "file_id": file_id},
        }

    def cache_attachment(self, issue_id: int, file_id: int, filename: str, content: bytes) -> Dict[str, Any]:
        issue_dir = self.settings.attachment_cache_path / str(issue_id)
        issue_dir.mkdir(parents=True, exist_ok=True)
        path = issue_dir / f"{file_id}-{safe_filename(filename)}"
        path.write_bytes(content)
        return {
            "cache_key": f"{issue_id}/{file_id}",
            "cached": True,
        }

    def build_agent_context(self, ticket: Dict[str, Any]) -> str:
        lines: List[str] = []
        lines.append(f"# Mantis #{ticket.get('id')}: {ticket.get('summary', '')}".strip())
        lines.append(f"URL: {ticket.get('url', '')}")
        if ticket.get("status_name"):
            lines.append(f"Status: {ticket['status_name']}")
        project = ticket.get("project")
        if isinstance(project, dict) and project.get("name"):
            lines.append(f"Project: {project.get('name')}")
        lines.append("")

        self.append_text_block(lines, "Description", ticket.get("description", {}))
        self.append_text_block(lines, "Steps to reproduce", ticket.get("steps_to_reproduce", {}))
        self.append_text_block(lines, "Additional information", ticket.get("additional_information", {}))

        if ticket.get("attachments"):
            lines.append("## Issue attachments")
            for attachment in ticket["attachments"]:
                self.append_attachment(lines, attachment)
            lines.append("")

        if ticket.get("comments"):
            lines.append("## Comments")
            for note in ticket["comments"]:
                reporter = note.get("reporter", {})
                author = first_non_empty(reporter.get("real_name"), reporter.get("name"), "unknown")
                lines.append(f"### Comment {note.get('id') or ''} by {author} at {note.get('created_at', '')}".strip())
                text = note.get("text", {})
                body = first_non_empty(text.get("agent_annotated_text"), text.get("plain_text"), text.get("raw_text"))
                if body:
                    lines.append(body)
                if note.get("attachments"):
                    lines.append("Attachments:")
                    for attachment in note["attachments"]:
                        self.append_attachment(lines, attachment)
                lines.append("")

        return "\n".join(lines).strip() + "\n"

    @staticmethod
    def append_text_block(lines: List[str], title: str, block: Dict[str, Any]) -> None:
        body = first_non_empty(block.get("agent_annotated_text"), block.get("plain_text"), block.get("raw_text"))
        if body:
            lines.append(f"## {title}")
            lines.append(body)
            lines.append("")

    @staticmethod
    def append_attachment(lines: List[str], attachment: Dict[str, Any]) -> None:
        filename = attachment.get("filename", "")
        handle = attachment.get("resource_handle", "")
        content_type = attachment.get("content_type", "")
        size = attachment.get("size", 0)
        lines.append(f"- {filename} ({content_type}, {size} bytes)")
        if handle:
            lines.append(f"  Original: {handle}")
        image = attachment.get("image")
        if isinstance(image, dict):
            lines.append("  Original image is the source of truth.")
            ocr = image.get("ocr", {})
            notice = ocr.get("notice") or OCR_NOTICE
            lines.append(f"  OCR note: {notice}")
            if ocr.get("text"):
                lines.append("  OCR draft:")
                for line in str(ocr.get("text")).splitlines():
                    lines.append(f"    {line}")
            elif ocr.get("error"):
                lines.append(f"  OCR error: {ocr.get('error')}")
        extracted = attachment.get("extracted_text", {})
        if isinstance(extracted, dict) and extracted.get("text"):
            lines.append(f"  Extracted text ({extracted.get('method')}):")
            for line in str(extracted.get("text")).splitlines():
                lines.append(f"    {line}")

    @staticmethod
    def as_list(value: Any) -> List[Any]:
        if isinstance(value, list):
            return value
        if value is None:
            return []
        return [value]


def create_mcp() -> Tuple[Any, MantisTicketService]:
    from fastmcp import FastMCP

    settings = Settings.from_env()
    service = MantisTicketService(settings)
    mcp = FastMCP("mantis-ticket", stateless_http=True)

    @mcp.tool
    def read_ticket(
        url_or_id: str,
        include_comments: bool = True,
        include_attachments: bool = True,
        image_ocr: bool = True,
    ) -> Dict[str, Any]:
        """Read a Mantis ticket by URL or id with comments, attachments, image originals, and OCR accompaniment."""
        try:
            return service.read_ticket(
                url_or_id=url_or_id,
                include_comments=include_comments,
                include_attachments=include_attachments,
                image_ocr=image_ocr,
            )
        except Exception as exc:
            return {"ok": False, "error": str(exc), "trace": traceback.format_exc(limit=3)}

    @mcp.tool
    def get_attachment(issue_id: int, file_id: int, include_content: bool = True) -> Dict[str, Any]:
        """Return the original Mantis attachment content as base64 by issue id and file id."""
        try:
            return service.get_attachment(issue_id=issue_id, file_id=file_id, include_content=include_content)
        except Exception as exc:
            return {"ok": False, "error": str(exc), "trace": traceback.format_exc(limit=3)}

    @mcp.tool
    def health() -> Dict[str, Any]:
        """Return basic Mantis ticket MCP configuration health without contacting Mantis."""
        return {
            "ok": True,
            "base_url_configured": bool(settings.base_url),
            "token_configured": bool(settings.api_token),
            "attachment_cache_path": str(settings.attachment_cache_path),
            "ocr_enabled": settings.ocr_enabled,
            "ocr_languages": list(settings.ocr_languages),
        }

    return mcp, service


def main() -> None:
    mcp, service = create_mcp()
    service.settings.attachment_cache_path.mkdir(parents=True, exist_ok=True)
    mcp.run(transport="http", host=service.settings.host, port=service.settings.port)


if __name__ == "__main__":
    main()
