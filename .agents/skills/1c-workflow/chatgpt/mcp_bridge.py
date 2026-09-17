#!/usr/bin/env python3
"""Optional ChatGPT/RDC adapter for ITL projects.

Reads an installed project's existing .codex/config.toml and forwards MCP calls
without rewriting client config or changing the normal Codex workflow.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
import tomllib
from typing import Any
from urllib import request

PROTOCOL_VERSION = "2025-06-18"
CLIENT_INFO = {"name": "itl-chatgpt-rdc-bridge", "version": "0.1.0"}
RULE_FILES = ("USER-RULES.md", "memory.md", "LLM-RULES.md", "AGENTS.md")


class BridgeError(RuntimeError):
    pass


def _configure_utf8_stdio() -> None:
    for stream in (sys.stdin, sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            reconfigure(encoding="utf-8", errors="strict")


def _project_root(value: str) -> Path:
    root = Path(value).expanduser().resolve()
    if not root.is_dir():
        raise BridgeError(f"Project root does not exist: {root}")
    return root


def load_servers(root: Path) -> dict[str, dict[str, Any]]:
    config = root / ".codex" / "config.toml"
    if not config.is_file():
        raise BridgeError(f"Missing MCP config: {config}")
    with config.open("rb") as stream:
        data = tomllib.load(stream)
    servers = data.get("mcp_servers") or {}
    if not isinstance(servers, dict):
        raise BridgeError("mcp_servers must be a TOML table")
    return {str(name): dict(spec) for name, spec in servers.items()}


def _server(root: Path, name: str) -> dict[str, Any]:
    servers = load_servers(root)
    if name not in servers:
        raise BridgeError(f"Unknown MCP server: {name}")
    spec = servers[name]
    if spec.get("enabled", True) is False:
        raise BridgeError(f"MCP server is disabled: {name}")
    return spec
def _decode_http(body: bytes, content_type: str) -> dict[str, Any] | None:
    text = body.decode("utf-8", errors="replace").strip()
    if not text:
        return None
    if "text/event-stream" in content_type:
        messages = []
        for line in text.splitlines():
            if line.startswith("data:"):
                payload = line[5:].strip()
                if payload and payload != "[DONE]":
                    messages.append(json.loads(payload))
        return messages[-1] if messages else None
    return json.loads(text)


class HttpMcpClient:
    def __init__(self, url: str, headers: dict[str, str] | None = None, timeout: float = 300):
        self.url = url
        self.headers = dict(headers or {})
        self.timeout = timeout
        self.session_id: str | None = None
        self.next_id = 1

    def _post(self, payload: dict[str, Any]) -> dict[str, Any] | None:
        headers = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json"}
        headers.update(self.headers)
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        req = request.Request(self.url, data=json.dumps(payload).encode("utf-8"), headers=headers, method="POST")
        with request.urlopen(req, timeout=self.timeout) as response:
            session = response.headers.get("Mcp-Session-Id")
            if session:
                self.session_id = session
            return _decode_http(response.read(), response.headers.get("Content-Type", ""))
    def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        payload: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        self._post(payload)

    def call(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        request_id = self.next_id
        self.next_id += 1
        payload: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            payload["params"] = params
        response = self._post(payload)
        if response is None:
            raise BridgeError(f"MCP returned no response for {method}")
        if response.get("error"):
            raise BridgeError(f"MCP {method} failed: {response['error']}")
        return response

    def initialize(self) -> None:
        self.call("initialize", {"protocolVersion": PROTOCOL_VERSION, "capabilities": {}, "clientInfo": CLIENT_INFO})
        self.notify("notifications/initialized")


class StdioMcpClient:
    def __init__(self, command: str, args: list[str], cwd: Path, env: dict[str, str] | None = None, timeout: float = 300):
        child_env = os.environ.copy()
        child_env.update({str(k): str(v) for k, v in (env or {}).items()})
        executable = os.path.expandvars(command)
        expanded_args = [os.path.expandvars(str(item)) for item in args]
        self.process = subprocess.Popen(
            [executable, *expanded_args], cwd=str(cwd), env=child_env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace", bufsize=1,
        )
        self.timeout = timeout
        self.next_id = 1
        self.output: queue.Queue[str | None] = queue.Queue()
        self.stderr: list[str] = []
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self) -> None:
        assert self.process.stdout is not None
        for line in self.process.stdout:
            self.output.put(line)
        self.output.put(None)

    def _read_stderr(self) -> None:
        assert self.process.stderr is not None
        for line in self.process.stderr:
            self.stderr.append(line.rstrip())
            if len(self.stderr) > 40:
                del self.stderr[:-40]

    def _send(self, payload: dict[str, Any]) -> None:
        if self.process.poll() is not None:
            raise BridgeError(f"MCP process exited with {self.process.returncode}: {' | '.join(self.stderr[-5:])}")
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
        self.process.stdin.flush()
    def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        payload: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        self._send(payload)

    def call(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        request_id = self.next_id
        self.next_id += 1
        payload: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            payload["params"] = params
        self._send(payload)
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            remaining = max(0.05, deadline - time.monotonic())
            try:
                line = self.output.get(timeout=remaining)
            except queue.Empty as exc:
                raise BridgeError(f"Timed out waiting for MCP {method}") from exc
            if line is None:
                raise BridgeError(f"MCP process closed stdout: {' | '.join(self.stderr[-5:])}")
            try:
                response = json.loads(line)
            except json.JSONDecodeError:
                continue
            if response.get("id") != request_id:
                continue
            if response.get("error"):
                raise BridgeError(f"MCP {method} failed: {response['error']}")
            return response
        raise BridgeError(f"Timed out waiting for MCP {method}")
    def initialize(self) -> None:
        self.call("initialize", {"protocolVersion": PROTOCOL_VERSION, "capabilities": {}, "clientInfo": CLIENT_INFO})
        self.notify("notifications/initialized")

    def close(self) -> None:
        if self.process.poll() is None:
            try:
                if self.process.stdin:
                    self.process.stdin.close()
                self.process.wait(timeout=2)
            except Exception:
                self.process.terminate()
                try:
                    self.process.wait(timeout=2)
                except Exception:
                    pass
        for stream in (self.process.stdout, self.process.stderr):
            if stream:
                stream.close()


def open_client(root: Path, name: str):
    spec = _server(root, name)
    timeout = float(spec.get("tool_timeout_sec", 300))
    if spec.get("url"):
        return HttpMcpClient(str(spec["url"]), spec.get("headers"), timeout)
    if spec.get("command"):
        return StdioMcpClient(str(spec["command"]), list(spec.get("args") or []), root, spec.get("env"), timeout)
    raise BridgeError(f"MCP server has neither url nor command: {name}")


def _git(root: Path, *args: str) -> str:
    result = subprocess.run(["git", "-c", "core.quotepath=false", *args], cwd=str(root), text=True,
                            encoding="utf-8", errors="replace", capture_output=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else ""
def project_info(root: Path) -> dict[str, Any]:
    servers = load_servers(root)
    rules = [str(root / name) for name in RULE_FILES if (root / name).is_file()]
    skills_root = root / ".agents" / "skills"
    return {
        "projectRoot": str(root),
        "gitBranch": _git(root, "branch", "--show-current"),
        "gitStatus": _git(root, "status", "--short", "--branch"),
        "ruleFilesInPrecedenceOrder": rules,
        "skillsRoot": str(skills_root) if skills_root.is_dir() else None,
        "mcpConfig": str(root / ".codex" / "config.toml"),
        "mcpServers": sorted(servers),
    }


def list_tools(root: Path, server: str) -> dict[str, Any]:
    client = open_client(root, server)
    try:
        client.initialize()
        tools: list[dict[str, Any]] = []
        cursor = None
        while True:
            params = {"cursor": cursor} if cursor else {}
            response = client.call("tools/list", params)
            result = response.get("result") or {}
            tools.extend(result.get("tools") or [])
            cursor = result.get("nextCursor")
            if not cursor:
                break
        return {"server": server, "tools": tools}
    finally:
        if hasattr(client, "close"):
            client.close()


def call_tool(root: Path, server: str, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
    client = open_client(root, server)
    try:
        client.initialize()
        response = client.call("tools/call", {"name": tool, "arguments": arguments})
        return {"server": server, "tool": tool, "result": response.get("result")}
    finally:
        if hasattr(client, "close"):
            client.close()


def session_loop(root: Path, server: str, input_stream, output_stream) -> None:
    """Keep one MCP client/facade alive across stateful tool calls."""
    client = open_client(root, server)
    try:
        client.initialize()
        for raw in input_stream:
            raw = raw.strip()
            if not raw:
                continue
            request_value = json.loads(raw)
            if not isinstance(request_value, dict):
                raise BridgeError("session request must be a JSON object")
            action = request_value.get("action")
            if action == "close":
                output_stream.write(json.dumps({"server": server, "status": "closed"}, ensure_ascii=False) + "\n")
                output_stream.flush()
                return
            if action == "tools-list":
                response = client.call("tools/list", {})
                value = {"server": server, "tools": (response.get("result") or {}).get("tools") or []}
            elif action == "tools-call":
                tool = request_value.get("tool")
                arguments = request_value.get("arguments", {})
                if not isinstance(tool, str) or not tool or not isinstance(arguments, dict):
                    raise BridgeError("session tools-call requires string tool and object arguments")
                response = client.call("tools/call", {"name": tool, "arguments": arguments})
                value = {"server": server, "tool": tool, "result": response.get("result")}
            else:
                raise BridgeError("unknown session action")
            output_stream.write(json.dumps(value, ensure_ascii=False) + "\n")
            output_stream.flush()
    finally:
        if hasattr(client, "close"):
            client.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Optional ChatGPT/RDC bridge for installed ITL projects")
    parser.add_argument("--project-root", required=True)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("project-info")
    sub.add_parser("servers")
    tools = sub.add_parser("tools-list")
    tools.add_argument("--server", required=True)
    call = sub.add_parser("tools-call")
    call.add_argument("--server", required=True)
    call.add_argument("--tool", required=True)
    call.add_argument("--arguments", default="{}", help="JSON object")
    session = sub.add_parser("session")
    session.add_argument("--server", required=True)
    args = parser.parse_args()
    root = _project_root(args.project_root)
    if args.action == "project-info":
        value = project_info(root)
    elif args.action == "servers":
        value = {"projectRoot": str(root), "servers": sorted(load_servers(root))}
    elif args.action == "tools-list":
        value = list_tools(root, args.server)
    elif args.action == "session":
        session_loop(root, args.server, sys.stdin, sys.stdout)
        return 0
    else:
        arguments = json.loads(args.arguments)
        if not isinstance(arguments, dict):
            raise BridgeError("--arguments must be a JSON object")
        value = call_tool(root, args.server, args.tool, arguments)
    print(json.dumps(value, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    _configure_utf8_stdio()
    try:
        raise SystemExit(main())
    except (BridgeError, json.JSONDecodeError, OSError) as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(2)
