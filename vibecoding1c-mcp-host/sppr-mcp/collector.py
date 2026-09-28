"""Operator CLI. Scheduling and source access stay outside the read-only MCP."""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import sys
from pathlib import Path

from sppr_core import Policy, Settings, SpprError, now
from sppr_embeddings import Embeddings
from sppr_odata import Collection, OData, collect
from sppr_store import Store, atomic_json, writer_lock


def require_user_session():
    if os.name != "nt":
        raise SpprError("Collection requires an open Windows user session on the configured host.")
    from ctypes import wintypes
    session = wintypes.DWORD()
    if not ctypes.windll.kernel32.ProcessIdToSessionId(os.getpid(), ctypes.byref(session)) or session.value == 0:
        raise SpprError("Collector is not in an interactive user session; sign in and run the managed task.")
    pointer, length = ctypes.c_void_p(), wintypes.DWORD()
    wts = ctypes.windll.wtsapi32
    wts.WTSQuerySessionInformationW.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.c_int,
                                              ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.DWORD)]
    wts.WTSFreeMemory.argtypes = [ctypes.c_void_p]
    if not wts.WTSQuerySessionInformationW(None, session, 8, ctypes.byref(pointer), ctypes.byref(length)):
        raise SpprError("Cannot verify the Windows user session; reconnect and retry the managed task.")
    try:
        state = ctypes.cast(pointer, ctypes.POINTER(ctypes.c_int)).contents.value
        if state not in (0, 1, 4):  # WTSActive, WTSConnected, WTSDisconnected.
            raise SpprError("User session is closing or unavailable; collection stopped.")
    finally:
        wts.WTSFreeMemory(pointer)


def load_credentials(path):
    try:
        result = json.loads(Path(path).read_text(encoding="utf-8-sig"))
        if not all(isinstance(result.get(k), str) and result[k] for k in ("username", "password")):
            raise ValueError()
        return result
    except (OSError, ValueError, TypeError):
        raise SpprError("Collector credential file is unavailable/invalid; configure username/password outside Git.") from None


def run(settings, credentials, operation="collect", outside_window=False, session_check=require_user_session):
    policy = Policy.load(settings.policy)
    store = Store(settings)

    def guard():
        session_check()
        policy.unchanged(settings.policy)
        if operation == "collect" and not outside_window and not settings.in_window():
            raise SpprError("Outside the night window; retry during the configured window. An operator can explicitly use --outside-window.")

    with writer_lock(settings.state):
        started = now()
        try:
            guard()
            atomic_json(settings.state / "attempt.json", {"state": "running", "started": started, "operation": operation})
            previous, vectors = store.previous()
            provider = Embeddings(settings, credentials.get("api_key", ""), before=guard)
            if operation == "embed-pending":
                with store.reader() as (db, manifest):
                    eligible = {k: v for k, v in previous.items() if policy.permits(v["roots"])}
                    edges = [json.loads(row[0]) for row in db.execute("SELECT data FROM edges")]
                    edges = [e for e in edges if e["source"] in eligible]
                    collection = Collection(eligible, edges, manifest["observed_start"], manifest["observed_end"], manifest["coverage"])
            else:
                source = OData(settings, credentials["username"], credentials["password"], before=guard)
                collection = collect(source, settings, policy, previous)
            guard()
            result = store.publish(collection, policy, provider, vectors, before=guard)
            atomic_json(settings.state / "attempt.json", {"state": "succeeded", "started": started, "finished": now(),
                                                         "operation": operation, "generation": result["generation"]})
            return result
        except (SpprError, KeyboardInterrupt) as exc:
            message = str(exc) if isinstance(exc, SpprError) else "Collection interrupted; previous generation retained."
            atomic_json(settings.state / "attempt.json", {"state": "failed", "started": started, "finished": now(),
                                                         "operation": operation, "message": message})
            raise
        except Exception:
            atomic_json(settings.state / "attempt.json", {"state": "failed", "started": started, "finished": now(),
                                                         "operation": operation, "message": "Unexpected local failure; previous generation retained. Check disk and runtime."})
            raise SpprError("Unexpected local failure; check disk and runtime. Details redacted.") from None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("collect", "embed-pending", "status", "rollback"))
    parser.add_argument("--config", required=True)
    parser.add_argument("--credentials")
    parser.add_argument("--outside-window", action="store_true", help="Explicit one-off operator authorization for a daytime full scan")
    parser.add_argument("--generation")
    args = parser.parse_args(argv)
    try:
        settings = Settings.load(args.config)
        if args.operation == "status":
            from sppr_service import Service
            result = Service(settings, Embeddings(settings, "")).status()
        elif args.operation == "rollback":
            with writer_lock(settings.state):
                result = Store(settings).rollback(args.generation or "")
        else:
            if not args.credentials:
                raise SpprError("Provide --credentials with an external collector credential file.")
            result = run(settings, load_credentials(args.credentials), args.operation, args.outside_window)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except SpprError as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
