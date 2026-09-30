import asyncio
import base64
import os
import sys
import tempfile
import threading
import types
import typing
import unittest
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import server


class FakeFastMCP:
    def __init__(self, name, **kwargs):
        self.name = name
        self.options = kwargs
        self.registered_tools = []
        self.tools = {}
        self.tool_options = {}

    def tool(self, function=None, **kwargs):
        def register(candidate):
            typing.get_type_hints(candidate)
            self.registered_tools.append(candidate.__name__)
            self.tools[candidate.__name__] = candidate
            self.tool_options[candidate.__name__] = kwargs
            return candidate

        if function is not None:
            return register(function)
        return register


class FakeContent:
    def __init__(self, **kwargs):
        for key, value in kwargs.items():
            setattr(self, key, value)


class FakeToolResult:
    def __init__(self, content=None, structured_content=None):
        self.content = content or []
        self.structured_content = structured_content


def fake_fastmcp_module():
    fastmcp = types.ModuleType("fastmcp")
    fastmcp.FastMCP = FakeFastMCP
    fastmcp_tools = types.ModuleType("fastmcp.tools")
    fastmcp_tool = types.ModuleType("fastmcp.tools.tool")
    fastmcp_tool.ToolResult = FakeToolResult
    mcp = types.ModuleType("mcp")
    mcp_types = types.ModuleType("mcp.types")
    mcp_types.ImageContent = FakeContent
    mcp_types.TextContent = FakeContent
    return {
        "fastmcp": fastmcp,
        "fastmcp.tools": fastmcp_tools,
        "fastmcp.tools.tool": fastmcp_tool,
        "mcp": mcp,
        "mcp.types": mcp_types,
    }


class FakeClient:
    def __init__(self):
        self.files = {
            10: {
                "id": 10,
                "filename": "status.png",
                "content_type": "image/png",
                "content": base64.b64encode(b"not-a-real-png").decode("ascii"),
            },
            11: {
                "id": 11,
                "filename": "notes.txt",
                "content_type": "text/plain",
                "content": base64.b64encode("line one\nline two".encode("utf-8")).decode("ascii"),
            },
        }

    def get_issue(self, issue_id):
        return {
            "id": issue_id,
            "summary": "Styled ticket",
            "status": {"name": "assigned", "label": "assigned"},
            "description": "Plain description",
            "attachments": [{"id": 10, "filename": "status.png", "content_type": "image/png", "size": 14}],
            "notes": [
                {
                    "id": 100,
                    "text": '<span style="color: red; font-weight: bold">Current status</span>',
                    "attachments": [{"id": 11, "filename": "notes.txt", "content_type": "text/plain", "size": 17}],
                }
            ],
        }

    def get_issue_file(self, issue_id, file_id):
        return self.files[file_id]


class FakeClientWithCommentImage(FakeClient):
    def __init__(self):
        super().__init__()
        self.files[12] = {
            "id": 12,
            "filename": "comment.png",
            "content_type": "image/png",
            "content": base64.b64encode(b"comment-image-bytes").decode("ascii"),
        }

    def get_issue(self, issue_id):
        issue = super().get_issue(issue_id)
        issue["notes"][0]["attachments"].append(
            {"id": 12, "filename": "comment.png", "content_type": "image/png", "size": 19}
        )
        return issue


class MantisTicketServerTests(unittest.TestCase):
    def test_search_reports_audit_timing_and_keeps_structured_output(self):
        from mantis_runtime import Runtime
        runtime = Runtime.__new__(Runtime)
        result = {"ok": True, "issues": [{"id": 1}], "next_cursor": "", "timing_ms": {"total": 5}}
        index = mock.Mock()
        index.search.return_value = result
        index.state.audit.return_value = {"audit_lock_wait": 3, "audit_write": 2}
        runtime.index = index
        mcp = FakeFastMCP("fixture")
        async def queued_search():
            loop = asyncio.get_running_loop()
            loop.set_default_executor(ThreadPoolExecutor(max_workers=1))
            held, release = threading.Event(), threading.Event()
            def occupy():
                held.set()
                release.wait(2)
            occupied = loop.run_in_executor(None, occupy)
            self.assertTrue(held.wait(2))
            timer = threading.Timer(0.08, release.set)
            timer.start()
            try:
                return await mcp.tools["search_tickets"]("atlas")
            finally:
                release.set()
                timer.cancel()
                await occupied
        with mock.patch.dict(sys.modules, fake_fastmcp_module()):
            runtime.register(mcp)
            response = asyncio.run(queued_search())
        self.assertIs(response.structured_content, result)
        self.assertEqual(5, result["timing_ms"]["total"])
        self.assertEqual(3, result["timing_ms"]["audit_lock_wait"])
        self.assertGreaterEqual(result["timing_ms"]["handler_total"], result["timing_ms"]["audit"])
        self.assertGreater(result["timing_ms"]["worker_queue"], 30)
        self.assertGreaterEqual(result["timing_ms"]["dispatch_total"], result["timing_ms"]["worker_queue"])
        self.assertEqual(["text"], [item.type for item in response.content])
        index.state.audit.assert_called_once()
        self.assertEqual("search", index.state.audit.call_args.args[1])

    def test_create_mcp_enables_stateless_http(self):
        with tempfile.TemporaryDirectory() as temp_root:
            environment = {
                "MANTIS_BASE_URL": "http://mantis.local",
                "MANTIS_API_TOKEN": "token",
                "MANTIS_ATTACHMENT_CACHE_PATH": temp_root,
            }
            with mock.patch.dict(os.environ, environment), mock.patch.dict(sys.modules, fake_fastmcp_module()):
                mcp, _ = server.create_mcp()

        self.assertEqual(mcp.name, "mantis-ticket")
        self.assertIs(mcp.options.get("stateless_http"), True)
        self.assertEqual(mcp.registered_tools, ["read_ticket", "read_comments", "ticket_history", "get_attachment", "health", "search_tickets",
                                                "mantis_metadata", "execute_write", "write_operation", "index_control"])

    def test_history_pages_visible_fields_and_hides_note_events(self):
        with tempfile.TemporaryDirectory() as tmp:
            client = FakeClient()
            original = client.get_issue
            events = [{"created_at": f"2026-09-{n:02d}T12:00:00Z", "user": {"id": 10, "name": "editor"},
                       "type": {"id": 0, "name": "field_changed"}, "field": {"name": "status"},
                       "old_value": {"id": 10, "name": "new"}, "new_value": {"id": 50, "name": "assigned"}} for n in range(1, 4)]
            events.append({"created_at": "2026-09-04T12:00:00Z", "type": {"name": "note_added"},
                           "note": {"id": 999}, "new_value": "PRIVATE_NOTE_987"})
            client.get_issue = lambda issue_id: {**original(issue_id), "history": events}
            service = server.MantisTicketService(server.Settings("http://mantis.local", "fixture", Path(tmp)), client)
            first = service.ticket_history("1", limit=1)
            self.assertEqual(len(first["events"]), 1)
            self.assertEqual(first["events"][0]["created_at"], "2026-09-03T12:00:00Z")
            self.assertEqual(first["omitted_unverified_events"], 1)
            self.assertNotIn("PRIVATE_NOTE_987", str(first))
            second = service.ticket_history("1", limit=1, cursor=first["next_cursor"])
            self.assertEqual(second["events"][0]["created_at"], "2026-09-02T12:00:00Z")
            self.assertEqual(len(service.ticket_history("1", from_date="2026-09-03T00:00:00Z")["events"]), 1)
            events[0]["new_value"] = {"id": 60, "name": "resolved"}
            self.assertEqual(service.ticket_history("1", cursor=first["next_cursor"])["status"], "history_changed")

    def test_comments_pages_long_text_and_detects_discussion_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            client = FakeClient()
            original = client.get_issue
            notes = [{"id": n, "created_at": f"2026-09-{n:02d}T12:00:00Z", "text": "x" * 7100 if n == 3 else f"note {n}",
                      "reporter": {"id": n, "name": f"user{n}"}} for n in range(1, 4)]
            client.get_issue = lambda issue_id: {**original(issue_id), "notes": notes}
            service = server.MantisTicketService(server.Settings("http://mantis.local", "fixture", Path(tmp)), client)
            first = service.read_comments("1", limit=1)
            self.assertEqual([c["id"] for c in first["comments"]], [3])
            self.assertFalse(first["comments"][0]["text_complete"])
            seen = first["comments"][0]["text"]
            cursor = first["next_cursor"]
            while cursor:
                page = service.read_comments("1", limit=1, cursor=cursor)
                if page["comments"][0]["id"] != 3:
                    break
                seen += page["comments"][0]["text"]
                cursor = page["next_cursor"]
            self.assertEqual(seen, "x" * 7100)
            self.assertEqual(service.read_comments("1", note_id=2)["comments"][0]["text"], "note 2")
            notes[0]["text"] = "changed"
            changed = service.read_comments("1", cursor=first["next_cursor"])
            self.assertEqual(changed["status"], "discussion_changed")

    def test_extract_issue_id_from_common_urls(self):
        self.assertEqual(server.extract_issue_id("123"), 123)
        self.assertEqual(server.extract_issue_id("http://mantis/view.php?id=456"), 456)
        self.assertEqual(server.extract_issue_id("http://mantis/api/rest/issues/789"), 789)

    def test_format_text_preserves_style_as_spans_and_agent_markers(self):
        result = server.format_text_block('<span style="color: red; font-weight: bold">Current status</span>')
        self.assertIn("Current status", result["plain_text"])
        self.assertTrue(any(span.get("color") == "red" for span in result["style_spans"]))
        self.assertIn("[color=red]", result["agent_annotated_text"])
        self.assertIn("[bold]", result["agent_annotated_text"])
        self.assertNotIn("<script", server.format_text_block("<script>alert(1)</script>ok")["rendered_html_sanitized"])

    def test_read_ticket_links_comment_attachment_without_default_ocr(self):
        with tempfile.TemporaryDirectory() as tmp:
            settings = server.Settings(
                base_url="http://mantis.local",
                api_token="secret",
                attachment_cache_path=Path(tmp),
                ocr_enabled=True,
            )
            service = server.MantisTicketService(settings=settings, client=FakeClient())
            result = service.read_ticket("http://mantis.local/view.php?id=1")

        self.assertTrue(result["ok"])
        ticket = result["ticket"]
        self.assertEqual(ticket["attachments"][0]["resource_handle"], "mantis://issue/1/files/10/status.png")
        self.assertEqual(ticket["comments"][0]["attachments"][0]["note_id"], 100)
        self.assertEqual(ticket["notes"][0]["attachments"][0]["note_id"], 100)
        self.assertEqual(ticket["comments"][0]["formatting_fidelity"], "mcp-rendered-from-rest")
        self.assertTrue(any(span.get("color") == "red" for span in ticket["comments"][0]["style_spans"]))
        self.assertIn("\u0427\u0435\u0440\u043d\u043e\u0432\u043e\u0435 OCR", server.OCR_NOTICE)
        self.assertFalse(ticket["attachments"][0]["image"]["ocr"]["enabled"])
        self.assertNotIn(server.OCR_NOTICE, ticket["agent_context_markdown"])
        self.assertIn("image_ocr=true", ticket["agent_context_markdown"])
        self.assertIn("Original image is the source of truth", ticket["agent_context_markdown"])

    def test_read_ticket_tool_returns_original_as_image_content_before_ocr_fallback(self):
        with tempfile.TemporaryDirectory() as temp_root:
            environment = {
                "MANTIS_BASE_URL": "http://mantis.local",
                "MANTIS_API_TOKEN": "token",
                "MANTIS_ATTACHMENT_CACHE_PATH": temp_root,
            }
            with mock.patch.dict(os.environ, environment), mock.patch.dict(sys.modules, fake_fastmcp_module()):
                mcp, service = server.create_mcp()
                service.client = FakeClient()
                result = asyncio.run(mcp.tools["read_ticket"]("1"))

        self.assertIsInstance(result, FakeToolResult)
        self.assertTrue(result.structured_content["ok"])
        self.assertFalse(result.structured_content["ticket"]["attachments"][0]["image"]["ocr"]["enabled"])
        self.assertEqual([item.type for item in result.content], ["text", "text", "image"])
        self.assertEqual(result.content[-1].mimeType, "image/png")
        self.assertEqual(base64.b64decode(result.content[-1].data), b"not-a-real-png")
        self.assertNotIn("OCR draft:", result.content[0].text)
        self.assertIn("image_ocr=true", result.content[1].text)

    def test_read_ticket_tool_keeps_original_when_ocr_fallback_is_requested(self):
        ocr_result = {
            "enabled": True,
            "notice": server.OCR_NOTICE,
            "text": "recognized fallback text",
            "languages": ["rus", "eng"],
            "error": "",
        }
        with tempfile.TemporaryDirectory() as temp_root:
            environment = {
                "MANTIS_BASE_URL": "http://mantis.local",
                "MANTIS_API_TOKEN": "token",
                "MANTIS_ATTACHMENT_CACHE_PATH": temp_root,
            }
            with mock.patch.dict(os.environ, environment), mock.patch.dict(sys.modules, fake_fastmcp_module()), mock.patch.object(
                server, "ocr_image", return_value=ocr_result
            ):
                mcp, service = server.create_mcp()
                service.client = FakeClient()
                result = asyncio.run(mcp.tools["read_ticket"]("1", image_ocr=True))

        self.assertEqual(result.content[-1].type, "image")
        self.assertIn("recognized fallback text", result.content[0].text)
        self.assertIn("analyze the original first", result.content[1].text)

    def test_read_ticket_tool_returns_images_attached_to_comments(self):
        with tempfile.TemporaryDirectory() as temp_root:
            environment = {
                "MANTIS_BASE_URL": "http://mantis.local",
                "MANTIS_API_TOKEN": "token",
                "MANTIS_ATTACHMENT_CACHE_PATH": temp_root,
            }
            with mock.patch.dict(os.environ, environment), mock.patch.dict(sys.modules, fake_fastmcp_module()):
                mcp, service = server.create_mcp()
                service.client = FakeClientWithCommentImage()
                result = asyncio.run(mcp.tools["read_ticket"]("1"))

        self.assertEqual([item.type for item in result.content], ["text", "text", "image", "text", "image"])
        self.assertIn("comment 100: comment.png", result.content[-2].text)
        self.assertEqual(base64.b64decode(result.content[-1].data), b"comment-image-bytes")

    def test_get_attachment_tool_returns_image_content_and_structured_base64(self):
        with tempfile.TemporaryDirectory() as temp_root:
            environment = {
                "MANTIS_BASE_URL": "http://mantis.local",
                "MANTIS_API_TOKEN": "token",
                "MANTIS_ATTACHMENT_CACHE_PATH": temp_root,
            }
            with mock.patch.dict(os.environ, environment), mock.patch.dict(sys.modules, fake_fastmcp_module()):
                mcp, service = server.create_mcp()
                service.client = FakeClient()
                result = asyncio.run(mcp.tools["get_attachment"](issue_id=1, file_id=10))

        self.assertEqual([item.type for item in result.content], ["text", "image"])
        self.assertNotIn("content_base64", result.content[0].text)
        self.assertEqual(
            base64.b64decode(result.structured_content["attachment"]["content_base64"]),
            b"not-a-real-png",
        )

    def test_get_attachment_reports_missing_backing_bytes(self):
        with tempfile.TemporaryDirectory() as temp_root:
            environment = {
                "MANTIS_BASE_URL": "http://mantis.local",
                "MANTIS_API_TOKEN": "token",
                "MANTIS_ATTACHMENT_CACHE_PATH": temp_root,
            }
            with mock.patch.dict(os.environ, environment), mock.patch.dict(sys.modules, fake_fastmcp_module()):
                mcp, service = server.create_mcp()
                service.client = FakeClient()
                service.client.files[10] = {"id": 10, "filename": "missing.docx", "size": 178534}
                result = asyncio.run(mcp.tools["get_attachment"](issue_id=1, file_id=10))
        attachment = result.structured_content["attachment"]
        self.assertFalse(attachment["original_available"])
        self.assertEqual(attachment["source_status"], "missing_source_bytes")
        self.assertEqual(attachment["content_base64"], "")


if __name__ == "__main__":
    unittest.main()
