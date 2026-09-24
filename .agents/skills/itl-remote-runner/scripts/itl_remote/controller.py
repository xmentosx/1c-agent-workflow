"""User-local discovery and on-demand lifecycle for paired pull brokers.

The controller owns only pairing discovery and broker startup. Job state stays
in the worker spool, so a restarted broker cannot replay a submitted job.
"""
from __future__ import annotations

import hashlib
import hmac
from http.client import HTTPConnection, HTTPSConnection
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import sys
import time
import uuid

from .common import FileLock, WorkError, publish_path, read_json, write_json
from .pull import _pull


_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}\Z")
_started_processes = {}


def controller_home():
    override = os.environ.get("ITL_REMOTE_CONTROLLER_HOME")
    if override:
        return Path(override).resolve()
    if os.name == "nt":
        local = os.environ.get("LOCALAPPDATA")
        if not local:
            raise WorkError("CONTROLLER_LOCALAPPDATA_REQUIRED")
        return Path(local) / "ITL" / "remote-work" / "controllers"
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "ITL" / "remote-work" / "controllers"


def _entry(name):
    if not isinstance(name, str) or not _NAME.fullmatch(name):
        raise WorkError("CONTROLLER_NAME_INVALID")
    return controller_home() / name


def _load(name):
    path = _entry(name)
    connection_path = path / "controller.json"
    settings_path = path / "broker.json"
    if not connection_path.is_file() or not settings_path.is_file():
        raise WorkError("CONTROLLER_NOT_REGISTERED: " + name)
    connection = read_json(connection_path)
    if connection.get("transport") != "pull":
        raise WorkError("CONTROLLER_PULL_REQUIRED")
    _pull(connection)
    settings = read_json(settings_path)
    if settings.get("schemaVersion") != 1 or not isinstance(settings.get("port"), int):
        raise WorkError("CONTROLLER_BROKER_SETTINGS_INVALID")
    return connection_path, connection, settings


def register(name, connection_file, *, listen="127.0.0.1", port=8765,
             certificate=None, private_key=None):
    path = _entry(name)
    connection = read_json(connection_file)
    if connection.get("transport") != "pull":
        raise WorkError("CONTROLLER_PULL_REQUIRED")
    _pull(connection)
    if (not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535 or
            bool(certificate) != bool(private_key)):
        raise WorkError("CONTROLLER_BROKER_SETTINGS_INVALID")
    if listen not in ("127.0.0.1", "localhost", "::1") and not certificate:
        raise WorkError("PULL_TLS_REQUIRED_FOR_NON_LOOPBACK_LISTENER")
    settings = {"schemaVersion": 1, "listen": listen, "port": port,
                "certificate": str(Path(certificate).resolve()) if certificate else None,
                "privateKey": str(Path(private_key).resolve()) if private_key else None}
    home = controller_home()
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    with FileLock(home / "catalog.lock"):
        if path.exists():
            old_path, old_connection, old_settings = _load(name)
            if old_connection != connection or old_settings != settings:
                raise WorkError("CONTROLLER_NAME_ALREADY_REGISTERED: " + name)
            return {"status": "already-registered", "name": name, "connection": str(old_path),
                    "url": _pull(connection)["url"]}
        stage = home / (".register-" + uuid.uuid4().hex)
        stage.mkdir(mode=0o700)
        try:
            write_json(stage / "controller.json", connection)
            write_json(stage / "broker.json", settings)
            if os.name != "nt":
                (stage / "controller.json").chmod(0o600)
                (stage / "broker.json").chmod(0o600)
            publish_path(stage, path)
        finally:
            if stage.exists():
                for item in stage.iterdir():
                    item.unlink()
                stage.rmdir()
    return {"status": "registered", "name": name, "connection": str(path / "controller.json"),
            "url": _pull(connection)["url"]}


def list_connections():
    home = controller_home()
    if not home.is_dir():
        return {"status": "ok", "connections": []}
    entries = []
    for path in sorted(home.iterdir()):
        if not path.is_dir() or not _NAME.fullmatch(path.name):
            continue
        connection_path, connection, settings = _load(path.name)
        entries.append({"name": path.name, "url": _pull(connection)["url"],
                        "workerId": _pull(connection)["workerId"],
                        "connection": str(connection_path), "listen": settings["listen"],
                        "port": settings["port"]})
    return {"status": "ok", "connections": entries}


def _health(connection, settings):
    pair = _pull(connection)
    nonce = uuid.uuid4().hex
    body = json.dumps({"workerId": pair["workerId"], "nonce": nonce})
    headers = {"Content-Type": "application/json; charset=utf-8"}
    client_type = HTTPSConnection if settings["certificate"] else HTTPConnection
    options = ({"context": ssl._create_unverified_context()} if settings["certificate"] else {})
    client = client_type(_local_host(settings), settings["port"], timeout=2, **options)
    try:
        client.request("POST", "/v1/health", body=body.encode("utf-8"), headers=headers)
        response = client.getresponse()
        raw = response.read(4096)
        value = json.loads(raw.decode("utf-8-sig"))
        broker_id = value.get("brokerId")
        if value.get("status") == "broker-ready" and isinstance(broker_id, str):
            expected = hmac.new(pair["token"].encode("utf-8"),
                                (nonce + "\0" + broker_id).encode("utf-8"), hashlib.sha256).hexdigest()
            if isinstance(value.get("proof"), str) and hmac.compare_digest(value["proof"], expected):
                return value
    except (OSError, ValueError, ssl.SSLError):
        return None
    finally:
        client.close()
    return None


def _local_host(settings):
    host = settings["listen"]
    if host in ("0.0.0.0", "localhost"):
        return "127.0.0.1"
    if host == "::":
        return "::1"
    return host


def _local_listener(settings):
    try:
        with socket.create_connection((_local_host(settings), settings["port"]), timeout=0.3):
            return True
    except OSError:
        return False


def _same_broker(connection, settings):
    for item in list_connections()["connections"]:
        _, candidate, candidate_settings = _load(item["name"])
        if _pull(candidate)["url"] == _pull(connection)["url"]:
            if candidate_settings != settings:
                raise WorkError("CONTROLLER_BROKER_SETTINGS_MISMATCH")
        elif candidate_settings["listen"] == settings["listen"] and candidate_settings["port"] == settings["port"]:
            raise WorkError("CONTROLLER_BROKER_PORT_SHARED_BY_DIFFERENT_URL")


def ensure(name):
    connection_path, connection, settings = _load(name)
    home = controller_home()
    lock_name = hashlib.sha256((settings["listen"] + ":" + str(settings["port"])).encode()).hexdigest()[:16]
    lock = home / ("broker-" + lock_name + ".lock")
    for attempt in range(51):
        try:
            with FileLock(lock):
                healthy = _health(connection, settings)
                if healthy:
                    return {"status": "broker-reused", "name": name, "connection": str(connection_path),
                            "url": _pull(connection)["url"], "brokerId": healthy["brokerId"]}
                if _local_listener(settings):
                    raise WorkError("BROKER_PORT_OCCUPIED_OR_PAIR_NOT_LOADED")
                _same_broker(connection, settings)
                runtime = Path(__file__).resolve().parent.parent / "remote_work.py"
                command = [sys.executable, "-B", "-X", "utf8", "-u", str(runtime),
                           "pull-serve", "--listen", settings["listen"], "--port", str(settings["port"]),
                           "--connection-directory", str(home)]
                if settings["certificate"]:
                    command += ["--certificate", settings["certificate"],
                                "--private-key", settings["privateKey"]]
                log_path = home / ("broker-" + lock_name + ".log")
                with log_path.open("ab") as log:
                    options = ({"creationflags": subprocess.CREATE_NO_WINDOW | subprocess.CREATE_NEW_PROCESS_GROUP}
                               if os.name == "nt" else {"start_new_session": True})
                    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log,
                                               stderr=subprocess.STDOUT, cwd=home, **options)
                    _started_processes[process.pid] = process
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    healthy = _health(connection, settings)
                    if healthy:
                        return {"status": "broker-started", "name": name,
                                "connection": str(connection_path), "url": _pull(connection)["url"],
                                "brokerId": healthy["brokerId"], "pid": process.pid}
                    if process.poll() is not None:
                        raise WorkError("BROKER_START_FAILED: exit=" + str(process.returncode))
                    time.sleep(0.2)
                process.terminate()
                process.wait(timeout=5)
                raise WorkError("BROKER_START_UNVERIFIED: " + str(log_path))
        except WorkError as error:
            if not str(error).startswith("OWNER_BUSY") or attempt == 50:
                raise
            time.sleep(0.1)
