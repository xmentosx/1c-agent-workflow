import base64
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import server


class FakeFastMCP:
    def __init__(self, name, **kwargs):
        self.name = name
        self.options = kwargs
        self.registered_tools = []

    def tool(self, function):
        self.registered_tools.append(function.__name__)
        return function


def fake_fastmcp_module():
    fastmcp = types.ModuleType("fastmcp")
    fastmcp.FastMCP = FakeFastMCP
    return fastmcp


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


class MantisTicketServerTests(unittest.TestCase):
    def test_create_mcp_enables_stateless_http(self):
        with tempfile.TemporaryDirectory() as temp_root:
            environment = {
                "MANTIS_BASE_URL": "http://mantis.local",
                "MANTIS_API_TOKEN": "token",
                "MANTIS_ATTACHMENT_CACHE_PATH": temp_root,
            }
            with mock.patch.dict(os.environ, environment), mock.patch.dict(sys.modules, {"fastmcp": fake_fastmcp_module()}):
                mcp, _ = server.create_mcp()

        self.assertEqual(mcp.name, "mantis-ticket")
        self.assertIs(mcp.options.get("stateless_http"), True)
        self.assertEqual(mcp.registered_tools, ["read_ticket", "get_attachment", "health"])

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

    def test_read_ticket_links_comment_attachment_and_marks_ocr_as_draft(self):
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
        self.assertIn(server.OCR_NOTICE, ticket["agent_context_markdown"])
        self.assertIn("Original image is the source of truth", ticket["agent_context_markdown"])


if __name__ == "__main__":
    unittest.main()
