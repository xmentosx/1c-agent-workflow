"""Outbound pull control channel for user-started workers.

The broker never connects to a worker.  A worker polls it from the interactive
user session and executes the same spool RPC contract used by SSH.  Shared
folders carry immutable blobs only; mutable job state always stays on pull.
"""
from __future__ import annotations

import hashlib
import hmac
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import ssl
import sys
import threading
import time
import uuid
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from .common import FileLock, WorkError, beneath, digest, publish_path, read_json, stamp, write_json


MAX_MESSAGE_BYTES = 2 * 1024 * 1024


def _pull(config):
    value = config.get("pull") if isinstance(config, dict) else None
    if not isinstance(value, dict):
        raise WorkError("PULL_CONNECTION_REQUIRED")
    url, worker, token = value.get("url"), value.get("workerId"), value.get("token")
    if not all(isinstance(item, str) and item for item in (url, worker, token)):
        raise WorkError("PULL_CONNECTION_INVALID")
    parsed = urlparse(url)
    if (parsed.scheme not in ("http", "https") or not parsed.hostname or
            parsed.username is not None or parsed.password is not None or parsed.query or parsed.fragment):
        raise WorkError("PULL_URL_INVALID")
    if parsed.scheme == "http" and parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
        raise WorkError("PULL_TLS_REQUIRED")
    if len(worker) > 128 or any(character in worker for character in "\r\n\0/"):
        raise WorkError("PULL_WORKER_ID_INVALID")
    if not 32 <= len(token) <= 512 or any(character in token for character in "\r\n\0"):
        raise WorkError("PULL_TOKEN_INVALID")
    return value


def _bulk_folders(config):
    result = {}
    values = config.get("bulkFolders", []) if isinstance(config, dict) else []
    if not isinstance(values, list):
        raise WorkError("BULK_FOLDERS_INVALID")
    for value in values:
        if (not isinstance(value, dict) or not isinstance(value.get("id"), str) or
                not value["id"] or value["id"] in result or not isinstance(value.get("path"), str)):
            raise WorkError("BULK_FOLDERS_INVALID")
        threshold = value.get("thresholdBytes", 64 * 1024 * 1024)
        if type(threshold) is not int or threshold < 0:
            raise WorkError("BULK_FOLDERS_INVALID")
        path = Path(value["path"])
        if not path.is_absolute():
            raise WorkError("BULK_FOLDER_ABSOLUTE_PATH_REQUIRED")
        result[value["id"]] = dict(value, path=str(path.resolve()), thresholdBytes=threshold)
    return result


def _http_json(config, route, value, *, timeout):
    pull = _pull(config)
    body = json.dumps(value, ensure_ascii=True, allow_nan=False).encode("utf-8")
    request = Request(pull["url"].rstrip("/") + route, data=body, method="POST",
                      headers={"Authorization": "Bearer " + pull["token"],
                               "Content-Type": "application/json; charset=utf-8"})
    try:
        with urlopen(request, timeout=timeout) as response:
            raw = response.read(MAX_MESSAGE_BYTES + 1)
    except HTTPError as error:
        raw = error.read(MAX_MESSAGE_BYTES + 1)
        try:
            detail = json.loads(raw.decode("utf-8-sig")).get("error")
        except (ValueError, UnicodeError, AttributeError):
            detail = None
        raise WorkError(detail or ("PULL_HTTP_ERROR: " + str(error.code))) from error
    except (OSError, URLError) as error:
        raise WorkError("PULL_CONNECTION_FAILED: " + str(error)) from error
    if len(raw) > MAX_MESSAGE_BYTES:
        raise WorkError("PULL_RESPONSE_TOO_LARGE")
    try:
        return json.loads(raw.decode("utf-8-sig")) if raw else {}
    except (ValueError, UnicodeError) as error:
        raise WorkError("PULL_RESPONSE_INVALID") from error


class BrokerState:
    """In-memory rendezvous. RPCs are idempotent spool operations by contract."""

    def __init__(self, allowed_identities=None, health_tokens=None, dynamic_identities=None):
        self.condition = threading.Condition()
        self.queues = {}
        self.responses = {}
        self.allowed_identities = None if allowed_identities is None else frozenset(allowed_identities)
        self.health_tokens = health_tokens or {}
        self.dynamic_identities = dynamic_identities
        self.broker_id = uuid.uuid4().hex

    @staticmethod
    def identity(worker, token):
        return hashlib.sha256((worker + "\0" + token).encode("utf-8")).hexdigest()

    def _identity(self, worker, token):
        identity = self.identity(worker, token)
        allowed = self.dynamic_identities()[0] if self.dynamic_identities is not None else self.allowed_identities
        if allowed is not None and identity not in allowed:
            raise WorkError("PULL_AUTH_INVALID")
        return identity

    def health_proof(self, worker, nonce):
        tokens = self.dynamic_identities()[1] if self.dynamic_identities is not None else self.health_tokens
        token = tokens.get(worker)
        if not token:
            raise WorkError("PULL_AUTH_INVALID")
        return hmac.new(token.encode("utf-8"),
                        (nonce + "\0" + self.broker_id).encode("utf-8"), hashlib.sha256).hexdigest()

    def call(self, worker, token, request_id, message, timeout):
        identity = self._identity(worker, token)
        response_key = (identity, request_id)
        deadline = time.monotonic() + timeout
        with self.condition:
            self.queues.setdefault(identity, []).append({"id": request_id, "message": message})
            self.condition.notify_all()
            while response_key not in self.responses:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise WorkError("PULL_RESPONSE_TIMEOUT")
                self.condition.wait(min(remaining, 1.0))
            return self.responses.pop(response_key)

    def pull(self, worker, token, timeout):
        identity = self._identity(worker, token)
        deadline = time.monotonic() + timeout
        with self.condition:
            while not self.queues.get(identity):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                self.condition.wait(min(remaining, 1.0))
            return self.queues[identity].pop(0)

    def respond(self, worker, token, request_id, response):
        identity = self._identity(worker, token)
        with self.condition:
            self.responses[(identity, request_id)] = response
            self.condition.notify_all()


class PullHttpServer(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False

    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)


def _handler(state):
    class Handler(BaseHTTPRequestHandler):
        server_version = "ITLPull/1"

        def log_message(self, *_):
            return

        def _json(self):
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError as error:
                raise WorkError("PULL_CONTENT_LENGTH_INVALID") from error
            if length <= 0 or length > MAX_MESSAGE_BYTES:
                raise WorkError("PULL_REQUEST_SIZE_INVALID")
            try:
                return json.loads(self.rfile.read(length).decode("utf-8-sig"))
            except (ValueError, UnicodeError) as error:
                raise WorkError("PULL_REQUEST_INVALID") from error

        def _token(self):
            prefix = "Bearer "
            value = self.headers.get("Authorization", "")
            if not value.startswith(prefix) or not 32 <= len(value) - len(prefix) <= 512:
                raise WorkError("PULL_AUTH_REQUIRED")
            token = value[len(prefix):]
            if any(character in token for character in "\r\n\0"):
                raise WorkError("PULL_AUTH_REQUIRED")
            return token

        def _send(self, status, value):
            raw = json.dumps(value, ensure_ascii=True, allow_nan=False).encode("utf-8")
            try:
                self.send_response(status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
            except (BrokenPipeError, ConnectionResetError):
                # A worker may stop immediately after its bounded poll returns.
                # The queued controller RPC and job state remain unaffected.
                return

        def do_POST(self):
            try:
                value = self._json()
                worker = value.get("workerId")
                if (not isinstance(worker, str) or not worker or len(worker) > 128 or
                        any(character in worker for character in "\r\n\0/")):
                    raise WorkError("PULL_WORKER_ID_INVALID")
                if self.path == "/v1/health":
                    nonce = value.get("nonce")
                    if not isinstance(nonce, str) or len(nonce) != 32 or any(c not in "0123456789abcdef" for c in nonce):
                        raise WorkError("PULL_HEALTH_NONCE_INVALID")
                    proof = state.health_proof(worker, nonce)
                    self._send(HTTPStatus.OK, {"status": "broker-ready", "brokerId": state.broker_id,
                                               "proof": proof})
                    return
                token = self._token()
                if self.path == "/v1/call":
                    request_id = value.get("requestId")
                    if not isinstance(request_id, str) or not request_id:
                        raise WorkError("PULL_REQUEST_ID_INVALID")
                    timeout = min(max(float(value.get("waitSeconds", 120)), 1), 300)
                    response = state.call(worker, token, request_id, value.get("message"), timeout)
                    self._send(HTTPStatus.OK, response)
                    return
                if self.path == "/v1/pull":
                    timeout = min(max(float(value.get("waitSeconds", 20)), 1), 30)
                    response = state.pull(worker, token, timeout)
                    self._send(HTTPStatus.OK, response or {})
                    return
                if self.path == "/v1/respond":
                    request_id = value.get("requestId")
                    if not isinstance(request_id, str) or not request_id:
                        raise WorkError("PULL_REQUEST_ID_INVALID")
                    state.respond(worker, token, request_id, value.get("response"))
                    self._send(HTTPStatus.OK, {"accepted": True})
                    return
                raise WorkError("PULL_ROUTE_UNKNOWN")
            except WorkError as error:
                if str(error) in ("PULL_AUTH_REQUIRED", "PULL_AUTH_INVALID"):
                    status = HTTPStatus.UNAUTHORIZED
                else:
                    status = (HTTPStatus.GATEWAY_TIMEOUT if str(error) == "PULL_RESPONSE_TIMEOUT"
                              else HTTPStatus.BAD_REQUEST)
                self._send(status, {"error": str(error)})
            except Exception:
                self._send(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "PULL_BROKER_ERROR"})

    return Handler


def start_broker(listen="127.0.0.1", port=0, *, certificate=None, private_key=None,
                 connections=None, connection_directory=None):
    if bool(certificate) != bool(private_key):
        raise WorkError("PULL_TLS_CERTIFICATE_AND_KEY_REQUIRED")
    if listen not in ("127.0.0.1", "localhost", "::1") and not (certificate and private_key):
        raise WorkError("PULL_TLS_REQUIRED_FOR_NON_LOOPBACK_LISTENER")
    allowed = None
    health_tokens = {}
    if connections is not None:
        allowed = set()
        for connection in connections:
            value = _pull(read_json(connection))
            allowed.add(BrokerState.identity(value["workerId"], value["token"]))
            if value["workerId"] in health_tokens and health_tokens[value["workerId"]] != value["token"]:
                health_tokens[value["workerId"]] = None
            elif value["workerId"] not in health_tokens:
                health_tokens[value["workerId"]] = value["token"]
        if not allowed:
            raise WorkError("PULL_BROKER_PAIRING_REQUIRED")
    dynamic = None
    if connection_directory is not None:
        directory = Path(connection_directory).resolve()
        cache_lock = threading.Lock()
        cache_mtime = None
        cache_allowed = set()
        cache_tokens = {}
        def dynamic():
            nonlocal cache_mtime, cache_allowed, cache_tokens
            with cache_lock:
                mtime = directory.stat().st_mtime_ns
                if mtime == cache_mtime:
                    return cache_allowed, cache_tokens
                current = set(allowed or ())
                tokens = dict(health_tokens)
                for path in directory.glob("*/controller.json"):
                    try:
                        settings = read_json(path.parent / "broker.json")
                        if (settings.get("listen") != listen or settings.get("port") != int(port) or
                                settings.get("certificate") != certificate or
                                settings.get("privateKey") != private_key):
                            continue
                        value = _pull(read_json(path))
                        current.add(BrokerState.identity(value["workerId"], value["token"]))
                        if value["workerId"] in tokens and tokens[value["workerId"]] != value["token"]:
                            tokens[value["workerId"]] = None
                        elif value["workerId"] not in tokens:
                            tokens[value["workerId"]] = value["token"]
                    except (OSError, ValueError, WorkError):
                        continue
                cache_mtime, cache_allowed, cache_tokens = mtime, current, tokens
                return current, tokens
        if not dynamic()[0]:
            raise WorkError("PULL_BROKER_PAIRING_REQUIRED")
    state = BrokerState(allowed, health_tokens=health_tokens, dynamic_identities=dynamic)
    server = PullHttpServer((listen, int(port)), _handler(state))
    scheme = "http"
    if certificate and private_key:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate, private_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        scheme = "https"
    host, selected_port = server.server_address[:2]
    thread = threading.Thread(target=server.serve_forever, name="itl-pull-broker", daemon=True)
    thread.start()
    url_host = "[" + host + "]" if ":" in host and not host.startswith("[") else host
    return server, thread, "%s://%s:%s" % (scheme, url_host, selected_port)


def serve(listen, port, *, certificate=None, private_key=None,
          connections=None, connection_directory=None):
    if not connections and not connection_directory:
        raise WorkError("PULL_BROKER_PAIRING_REQUIRED")
    server, thread, url = start_broker(listen, port, certificate=certificate, private_key=private_key,
                                       connections=connections, connection_directory=connection_directory)
    print(json.dumps({"status": "pull-broker-ready", "url": url}, ensure_ascii=True), flush=True)
    try:
        thread.join()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
    return {"status": "pull-broker-stopped", "url": url}


class PullConnection:
    def __init__(self, config):
        self.config = config
        self.pull = _pull(config)

    def call(self, message):
        request_id = uuid.uuid4().hex
        timeout = min(max(float(self.pull.get("timeoutSeconds", 120)), 1), 300)
        value = _http_json(self.config, "/v1/call",
                           {"workerId": self.pull["workerId"], "requestId": request_id,
                            "message": message, "waitSeconds": timeout}, timeout=timeout + 5)
        if isinstance(value, dict) and value.get("error"):
            raise WorkError(value["error"])
        return value


def _copy_verified(source, destination, expected_size, expected_hash):
    source, destination = Path(source), Path(destination)
    if not source.is_file() or source.stat().st_size != expected_size or digest(source) != expected_hash:
        raise WorkError("BULK_BLOB_UNAVAILABLE")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with FileLock(destination.with_suffix(".lock")):
        if destination.is_file() and destination.stat().st_size == expected_size and digest(destination) == expected_hash:
            return
        temporary = destination.with_name(destination.name + "." + uuid.uuid4().hex + ".tmp")
        try:
            shutil.copyfile(source, temporary)
            if temporary.stat().st_size != expected_size or digest(temporary) != expected_hash:
                raise WorkError("BULK_BLOB_HASH_MISMATCH")
            publish_path(temporary, destination, replace=True)
        finally:
            temporary.unlink(missing_ok=True)


class PullWorker:
    def __init__(self, config, spool, stop_event):
        self.config = config
        self.pull = _pull(config)
        self.folders = _bulk_folders(config)
        self.spool = Path(spool).resolve()
        self.stop_event = stop_event
        self.last_connection = None
        self.last_connection_at = 0.0
        self.thread = threading.Thread(target=self._run, name="itl-pull-worker", daemon=True)

    def start(self):
        self.thread.start()

    def _publish_connection(self, value):
        state = (value["status"], value.get("error", ""))
        now = time.monotonic()
        if state == self.last_connection and now - self.last_connection_at < 10:
            return
        write_json(self.spool / "pull-connection.json", value)
        self.last_connection = state
        self.last_connection_at = now
        try:
            profile = read_json(self.spool / "profile.json")
            path = profile.get("bootstrapStatusPath")
            if isinstance(path, str) and Path(path).is_absolute():
                write_json(path, {"schemaVersion": 1, "phase": value["status"],
                                  "detail": value.get("error", ""), "workerId": value["workerId"],
                                  "updatedAt": value["updatedAt"]})
        except (OSError, ValueError, WorkError):
            # Diagnostics on an optional transfer folder never stop pull.
            pass

    def stop(self):
        self.stop_event.set()
        self.thread.join(timeout=10)

    def _folder_path(self, folder_id, kind, sha):
        folder = self.folders.get(folder_id)
        if folder is None:
            raise WorkError("BULK_FOLDER_NOT_CONFIGURED")
        return beneath(folder["path"], "%s/%s" % (kind, sha))

    def _dispatch(self, message):
        operation = message.get("operation") if isinstance(message, dict) else None
        if operation == "adopt-blob":
            source = self._folder_path(message.get("folderId"), "itl-blobs", message.get("sha256"))
            from .transport import blob_path
            destination = blob_path(self.spool, message["sha256"])
            _copy_verified(source, destination, message["bytes"], message["sha256"])
            return {"adopted": message["sha256"], "channel": "folder"}
        if operation == "export-result":
            from .transport import public_result_path
            source = public_result_path(self.spool / "runs" / message["id"], message["path"])
            if (not source.is_file() or source.stat().st_size != message["bytes"] or
                    digest(source) != message["sha256"]):
                raise WorkError("RESULT_CHANGED_DURING_EXPORT")
            destination = self._folder_path(message.get("folderId"), "itl-results", message["sha256"])
            _copy_verified(source, destination, message["bytes"], message["sha256"])
            return {"exported": message["sha256"], "channel": "folder"}
        if operation == "stage-update":
            from .updates import stage
            return stage(self.spool, message, self.config)
        from .transport import endpoint
        return endpoint(self.spool, message)

    def _run(self):
        while not self.stop_event.is_set():
            try:
                call = _http_json(self.config, "/v1/pull",
                                  {"workerId": self.pull["workerId"], "waitSeconds": 2}, timeout=10)
                self._publish_connection({"status": "connected", "updatedAt": stamp(),
                                          "workerId": self.pull["workerId"]})
                if not call:
                    continue
                try:
                    response = self._dispatch(call.get("message"))
                except Exception as error:
                    response = {"error": str(error)}
                _http_json(self.config, "/v1/respond",
                           {"workerId": self.pull["workerId"], "requestId": call.get("id"),
                            "response": response}, timeout=15)
            except WorkError as error:
                self._publish_connection({"status": "disconnected", "updatedAt": stamp(),
                                          "workerId": self.pull["workerId"], "error": str(error)})
                self.stop_event.wait(1.0)
