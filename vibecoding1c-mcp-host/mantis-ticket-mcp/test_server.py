import base64
import os
import sys
import tempfile
import types
import typing
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
                result = mcp.tools["read_ticket"]("1")

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
                result = mcp.tools["read_ticket"]("1", image_ocr=True)

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
                result = mcp.tools["read_ticket"]("1")

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
                result = mcp.tools["get_attachment"](issue_id=1, file_id=10)

        self.assertEqual([item.type for item in result.content], ["text", "image"])
        self.assertNotIn("content_base64", result.content[0].text)
        self.assertEqual(
            base64.b64decode(result.structured_content["attachment"]["content_base64"]),
            b"not-a-real-png",
        )


if __name__ == "__main__":
    unittest.main()
