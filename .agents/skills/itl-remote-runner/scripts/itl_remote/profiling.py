"""Scoped 1C HTTP RDBG capture and offline PerformanceInfoMain analysis.

Protocol shapes follow the retained 8.3.27 measurement requests. Raw packets,
including the native response bytes, remain evidence; this is not a PFF writer.
"""
from __future__ import annotations

import http.client
from pathlib import Path
import threading
import time
import urllib.parse
import uuid
import xml.etree.ElementTree as ET
import zlib

from .common import OwnedProcess, WorkError, beneath, digest, read_json, stamp, write_json

RESPONSE = "http://v8.1c.ru/8.3/debugger/debugRDBGRequestResponse"
DATA = "http://v8.1c.ru/8.3/debugger/debugBaseData"
MEASURE = "http://v8.1c.ru/8.3/debugger/debugMeasure"
COMMANDS = "http://v8.1c.ru/8.3/debugger/debugDBGUICommands"
ET.register_namespace("response", RESPONSE)
ET.register_namespace("data", DATA)


def prepare_debug_server(target, run, processes, cancelled):
    """File bases get a job-owned loopback server on the execution host.

    Server bases use an explicitly configured endpoint; shared dbgs is never
    started/stopped here. The notify file proves that our local process bound
    its port, so a port-selection race cannot attach us to another listener.
    """
    import socket
    config = dict(target.get("rdbg") or {})
    kind = target.get("infoBase", {}).get("kind")
    if kind == "server":
        if config.get("mode", "shared") != "shared":
            raise WorkError("SERVER_BASE_REQUIRES_SHARED_RDBG_ENDPOINT")
        return config if config.get("url") and config.get("infoBaseAlias") else None
    if kind != "file":
        return config if config.get("url") else None
    if config.get("mode", "local") != "local":
        raise WorkError("FILE_BASE_REQUIRES_EXECUTION_HOST_RDBG")
    if not config.get("infoBaseAlias"):
        return None
    executable = config.get("executable")
    if not executable and target.get("platform"):
        executable = str(Path(target["platform"]).parent / "dbgs.exe")
    if not executable or not Path(executable).is_file():
        return None
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    notification = Path(run) / "dbgs-url.txt"
    if notification.exists():
        raise WorkError("STALE_DBGS_NOTIFICATION")
    command = [str(executable), "--addr=127.0.0.1", "--port=" + str(port), "--notify=" + str(notification)]
    process = OwnedProcess(command, target["workspace"], Path(run) / "dbgs.log")
    processes.append(process)
    deadline = time.monotonic() + config.get("startTimeoutSeconds", 30)
    while not notification.exists():
        if cancelled():
            raise WorkError("CANCELLED")
        if process.process.poll() is not None:
            raise WorkError("LOCAL_DBGS_START_FAILED")
        if time.monotonic() >= deadline:
            raise WorkError("LOCAL_DBGS_START_TIMEOUT")
        time.sleep(0.05)
    raw_notification = notification.read_bytes()
    advertised = raw_notification.decode("utf-16" if raw_notification.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig").strip()
    url = "http://127.0.0.1:" + str(port)
    if advertised not in (url, url.removeprefix("http://")) or process.process.poll() is not None:
        raise WorkError("LOCAL_DBGS_ENDPOINT_UNPROVEN")
    config.update(mode="local", url=url)
    write_json(Path(run) / "dbgs-process.json", {"pid": process.process.pid, "url": url,
                                                "executionHostLocal": True, "startedAt": stamp()})
    return config



def runtime_proof(context_path, client_pid, seance, instance):
    """Discover targets for an explicitly identified runtime session, without attaching them."""
    from .common import capture
    context_path = Path(context_path)
    context = read_json(context_path)
    run = context_path.parent
    record_path = run / ("onec-process-%d.json" % client_pid)
    record = read_json(record_path)
    if record.get("jobId") != context["jobId"] or record.get("infoBase") != context["target"].get("infoBase"):
        raise WorkError("RDBG_FOREIGN_CLIENT_LAUNCH")
    capture(["powershell.exe", "-NoProfile", "-File", str(Path(__file__).resolve().parent.parent / "Test-OneCProcessRecord.ps1"),
             "-RecordPath", str(record_path)], timeout=20)
    config = context["rdbg"]
    proof = {"jobId": context["jobId"], "clientPid": client_pid, "infoBaseAlias": config["infoBaseAlias"],
             "seanceId": seance, "infoBaseInstanceID": instance, "targetIds": ["discovery-only"]}
    debugger = Rdbg(config, proof, run / "discovery" / uuid.uuid4().hex)
    try:
        response = debugger.call("attachDebugUI")
        if response.findtext("{" + RESPONSE + "}result") != "registered":
            raise WorkError("RDBG_REGISTRATION_REFUSED")
        debugger.registered = True
        debugger.call("initSettings")
        targets = [fields(t) for t in debugger.call("getDbgTargets").findall("{" + RESPONSE + "}id")]
        selected = [t for t in targets if all(t.get(k) == proof[k] for k in ("infoBaseAlias", "seanceId", "infoBaseInstanceID"))
                    and t.get("targetType") in ("ManagedClient", "Server")]
        proof["targetIds"] = [t["id"] for t in selected]
        if not selected:
            raise WorkError("RDBG_OWNED_SESSION_NOT_DISCOVERED")
        proof["observedAt"] = stamp()
        write_json(run / "runtime-proof.json", proof)
        return proof
    finally:
        debugger.close()


def fields(element):
    return {child.tag.rsplit("}", 1)[-1]: child.text for child in element}


def analyze_raw(paths, session=None, expected=None, source_map=None):
    packets = {}
    for path in paths:
        root = ET.fromstring(Path(path).read_bytes())
        for measure in root.iter("{" + COMMANDS + "}measure"):
            sid = measure.findtext("{" + MEASURE + "}sessionID")
            if session and sid != session:
                continue
            target_node = measure.find("{" + MEASURE + "}targetID")
            if target_node is None:
                raise WorkError("PROFILE_TARGET_MISSING")
            target = fields(target_node)
            if expected and (target.get("id") not in expected["targetIds"] or
                             target.get("seanceId") != expected["seanceId"] or
                             target.get("infoBaseAlias") != expected["infoBaseAlias"] or
                             target.get("infoBaseInstanceID") != expected["infoBaseInstanceID"]):
                raise WorkError("FOREIGN_PROFILE_PACKET")
            hz = float(measure.findtext("{" + MEASURE + "}performanceFrequency", "0"))
            if hz <= 0:
                raise WorkError("INVALID_PROFILE_FREQUENCY")
            rows = []
            modules = measure.findall("{" + MEASURE + "}moduleData")
            for module in modules:
                module_id = fields(module.find("{" + MEASURE + "}moduleID"))
                mapping = (source_map or {}).get(module_id.get("id", ""))
                source_match = {"sourceMatched": False}
                if mapping and mapping.get("moduleVersion") == module_id.get("version"):
                    source = Path(mapping["path"])
                    try:
                        if source.is_file() and digest(source) == mapping["sha256"]:
                            source_match.update(sourceMatched=True, source=str(source))
                    except OSError as error:
                        source_match["sourceIssue"] = str(error)
                for line in module.findall("{" + MEASURE + "}lineInfo"):
                    row = {key: float(value) for key, value in fields(line).items()}
                    row.update(moduleID=module_id, seconds=row["durability"] / hz,
                               pureSeconds=row["pureDurability"] / hz, sourceMatched=False)
                    row.update(source_match)
                    rows.append(row)
            key = (sid, target["id"])
            packet = {"sessionId": sid, "target": target, "raw": str(path), "sha256": digest(path),
                      "bytes": Path(path).stat().st_size, "frequency": hz,
                      "totalSeconds": float(measure.findtext("{" + MEASURE + "}totalDurability", "0")) / hz,
                      "modules": len(modules), "lines": len(rows),
                      "top": sorted(rows, key=lambda row: row["pureSeconds"], reverse=True)[:30]}
            import hashlib
            packet["measureSha256"] = hashlib.sha256(ET.canonicalize(ET.tostring(measure, encoding="unicode"), strip_text=True).encode("utf-8")).hexdigest()
            if key in packets:
                if packets[key]["measureSha256"] != packet["measureSha256"]:
                    raise WorkError("DUPLICATE_PROFILE_TARGET: ambiguous packet for " + str(key))
                continue
            packets[key] = packet
    values = list(packets.values())
    complete = bool(values) and (not expected or (
        {p["target"]["id"] for p in values} == set(expected["targetIds"]) and
        set(expected.get("requiredTypes", [])) <= {p["target"].get("targetType") for p in values}))
    return {"format": "PerformanceInfoMain", "pff": None, "complete": complete, "packets": values}


class Rdbg:
    def __init__(self, configuration, proof, output):
        self.config = configuration
        self.proof = proof
        self.output = Path(output)
        self.output.mkdir(parents=True, exist_ok=True)
        self.debugger = str(uuid.uuid4())
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.thread = None
        self.registered = False
        self.attached = False
        self.measuring = False
        self.error = None
        self.serial = 0
        self.raw = []
        self.url = urllib.parse.urlsplit(configuration["url"])
        if self.url.scheme not in ("http", "https") or not self.url.hostname or self.url.username:
            raise WorkError("INVALID_RDBG_ENDPOINT")
        for name in ("targetIds", "seanceId", "infoBaseInstanceID", "infoBaseAlias"):
            if not proof.get(name):
                raise WorkError("RDBG_OWNERSHIP_PROOF_MISSING: " + name)
        if proof["infoBaseAlias"] != configuration["infoBaseAlias"]:
            raise WorkError("RDBG_INFOBASE_MISMATCH")

    def call(self, command, *, session=None, attach=None):
        with self.lock:
            root = ET.Element("request")
            for name, value in (("infoBaseAlias", self.proof["infoBaseAlias"]), ("idOfDebuggerUI", self.debugger)):
                ET.SubElement(root, "{" + RESPONSE + "}" + name).text = value
            if command == "attachDebugUI":
                ET.SubElement(root, "{" + RESPONSE + "}credentials").text = ""
            if command == "setMeasureMode" and session:
                ET.SubElement(root, "{" + RESPONSE + "}measureModeSeanceID").text = session
            if command == "attachDetachDbgTargets":
                ET.SubElement(root, "{" + RESPONSE + "}attach").text = "true" if attach else "false"
                for target in self.proof["targetIds"]:
                    item = ET.SubElement(root, "{" + RESPONSE + "}id")
                    ET.SubElement(item, "{" + DATA + "}id").text = target
            query = {"cmd": command}
            body = ET.tostring(root, encoding="utf-8", xml_declaration=True)
            if command == "pingDebugUIParams":
                query["dbgui"] = self.debugger
                body = b""
            connection_type = http.client.HTTPSConnection if self.url.scheme == "https" else http.client.HTTPConnection
            conn = connection_type(self.url.hostname, self.url.port, timeout=15)
            self.serial += 1
            prefix = self.output / ("%06d-%s" % (self.serial, command))
            prefix.with_suffix(".request.xml").write_bytes(body)
            try:
                conn.request("POST", "/e1crdbg/rdbg?" + urllib.parse.urlencode(query), body=body,
                             headers={"Content-Type": "application/xml", "Accept": "application/xml",
                                      "1C-ApplicationName": "1C:Enterprise DT", "User-Agent": "1CV8"})
                response = conn.getresponse()
                raw = response.read()
                prefix.with_suffix(".response.bin").write_bytes(raw)
                encoding = response.getheader("Content-Encoding", "").lower()
                if encoding == "deflate":
                    try:
                        raw = zlib.decompress(raw)
                    except zlib.error:
                        raw = zlib.decompress(raw, -zlib.MAX_WBITS)
                elif encoding == "gzip":
                    raw = zlib.decompress(raw, 16 + zlib.MAX_WBITS)
                path = prefix.with_suffix(".response.xml")
                path.write_bytes(raw)
                if response.status != 200:
                    raise WorkError("RDBG_HTTP_ERROR: " + str(response.status))
                tree = ET.fromstring(raw)
                if command == "pingDebugUIParams":
                    self.raw.append(path)
                return tree
            finally:
                conn.close()

    def open(self):
        response = self.call("attachDebugUI")
        result = response.findtext("{" + RESPONSE + "}result")
        if result != "registered":
            raise WorkError("RDBG_REGISTRATION_REFUSED: " + str(result))
        self.registered = True
        try:
            self.call("initSettings")
            targets = self.call("getDbgTargets")
            observed = {fields(item).get("id"): fields(item) for item in targets.findall("{" + RESPONSE + "}id")}
            for identifier in self.proof["targetIds"]:
                item = observed.get(identifier, {})
                for key in ("seanceId", "infoBaseInstanceID", "infoBaseAlias"):
                    if item.get(key) != self.proof[key]:
                        raise WorkError("RDBG_TARGET_OWNERSHIP_MISMATCH")
            types = {observed[identifier].get("targetType") for identifier in self.proof["targetIds"]}
            if not set(self.proof.get("requiredTypes", [])) <= types:
                raise WorkError("RDBG_TARGET_FAMILIES_INCOMPLETE")
            self.call("attachDetachDbgTargets", attach=True)
            self.attached = True
            self.thread = threading.Thread(target=self._poll, daemon=True)
            self.thread.start()
        except BaseException:
            self.close()
            raise

    def _poll(self):
        while not self.stop_event.wait(0.5):
            try:
                self.call("pingDebugUIParams")
            except Exception as error:
                self.error = error
                return

    def start(self):
        if self.error:
            raise self.error
        self.session = str(uuid.uuid4())
        self.call("setMeasureMode", session=self.session)
        self.measuring = True

    def finish(self):
        self.call("setMeasureMode")
        self.measuring = False
        deadline = time.monotonic() + self.config.get("collectTimeoutSeconds", 30)
        result = None
        while time.monotonic() < deadline:
            if self.error:
                raise self.error
            self.call("pingDebugUIParams")
            result = analyze_raw(list(self.raw), self.session, self.proof)
            if result["complete"]:
                break
            time.sleep(0.2)
        if not result or not result["complete"]:
            raise WorkError("PROFILE_INCOMPLETE")
        write_json(self.output / "profile.json", result)
        return result

    def close(self):
        self.stop_event.set()
        if self.thread:
            self.thread.join(timeout=20)
        failures = []
        for enabled, command, kwargs in ((self.measuring, "setMeasureMode", {}),
                                          (self.attached, "attachDetachDbgTargets", {"attach": False}),
                                          (self.registered, "detachDebugUI", {})):
            if enabled:
                try:
                    self.call(command, **kwargs)
                except Exception as error:
                    failures.append(str(error))
        write_json(self.output / "cleanup.json", {"at": stamp(), "errors": failures})
        if failures:
            raise WorkError("RDBG_CLEANUP_INCOMPLETE: " + "; ".join(failures))
