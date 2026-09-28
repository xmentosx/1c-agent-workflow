"""Bounded retrieval over one immutable generation and a freshly read project policy."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import secrets
import sqlite3
from collections import defaultdict

import numpy as np

from sppr_core import (FILTER_FIELDS, KINDS, Policy, SpprError, canonical, digest,
                       guid, navigation, split_key)
from sppr_embeddings import QueryCache
from sppr_links import IDEA, MEMBERSHIP, PARENT, development_context
from sppr_store import Store


class Service:
    def __init__(self, settings, provider):
        self.settings = settings
        self.store = Store(settings)
        self.queries = QueryCache(settings, provider)
        self.cursor_key = secrets.token_bytes(32)

    @staticmethod
    def limit(value):
        if not isinstance(value, int) or isinstance(value, bool) or not 1 <= value <= 20:
            raise SpprError("limit must be between 1 and 20; use continuation for more results.")
        return value

    def cursor(self, token, context):
        if not token:
            return 0
        try:
            if len(token) > 4096:
                raise ValueError()
            raw = base64.urlsafe_b64decode(token.encode("ascii"))
            signature, payload = raw[:32], raw[32:]
            if not hmac.compare_digest(signature, hmac.digest(self.cursor_key, payload, "sha256")):
                raise ValueError()
            data = json.loads(payload)
            if data["context"] != context or type(data["offset"]) is not int or data["offset"] < 0:
                raise ValueError()
            return data["offset"]
        except (ValueError, KeyError, TypeError, UnicodeError):
            raise SpprError("Continuation expired or parameters/policy changed; repeat the original request without cursor.") from None

    def next_cursor(self, offset, context):
        payload = canonical({"offset": offset, "context": context}).encode("utf-8")
        return base64.urlsafe_b64encode(hmac.digest(self.cursor_key, payload, "sha256") + payload).decode("ascii")

    def envelope(self, manifest, policy):
        return {"generation": manifest["generation"], "source": manifest["source"], "observed_start": manifest["observed_start"],
                "observed_end": manifest["observed_end"], "mode": manifest["mode"],
                "coverage": manifest["coverage"], "coverage_scope": "published generation before current policy filtering",
                "profile_compatible": manifest["profile"] == self.settings.profile,
                "current_policy": policy.token}

    def objects(self, db, policy):
        if not policy.projects:
            return {}
        placeholders = ",".join("?" for _ in policy.projects)
        sql = f"SELECT DISTINCT o.id,o.data FROM objects o JOIN roots r ON r.object_id=o.id WHERE r.project IN ({placeholders})"
        return {row["id"]: json.loads(row["data"]) for row in db.execute(sql, sorted(policy.projects))}

    def summary(self, obj, policy):
        # Never return obsolete provenance paths for a revoked project.
        roots = sorted(set(obj["roots"]) & policy.projects)
        provenance = {p: path for p, path in obj["provenance"].items() if p in policy.projects}
        return {"id": obj["id"], "type": obj["kind"], "title": obj["title"][:300],
                "title_truncated": len(obj["title"]) > 300,
                "project": obj["project"], "roots": roots[:20], "root_count": len(roots),
                "provenance": {p: path[:8] for p, path in list(provenance.items())[:3]},
                "provenance_complete": len(provenance) <= 3 and all(len(path) <= 8 for path in provenance.values()),
                "is_folder": obj["is_folder"], "observed_at": obj["observed_at"],
                "tp_role": obj.get("tp_role"),
                "links": navigation(self.settings, obj["kind"], obj["uuid"])}

    def checked(self, response, policy):
        policy.unchanged(self.settings.policy)
        return response

    def search(self, query, filters=None, limit=10):
        self.limit(limit)
        if not isinstance(query, str) or not query.strip() or len(query) > 4000:
            raise SpprError("Provide a nonempty query of at most 4000 characters.")
        filters = filters or {}
        if not isinstance(filters, dict) or set(filters) - (set(FILTER_FIELDS) | {"project", "type"}):
            raise SpprError("Supported filters: project, type, status, developer, tester, business_type, sprint.")
        if any(not isinstance(v, str) or len(v) > 500 for v in filters.values()):
            raise SpprError("Filter values must be strings of at most 500 characters.")
        if "type" in filters and filters["type"] not in KINDS:
            raise SpprError("Unsupported metadata type filter.")
        policy = Policy.load(self.settings.policy)
        with self.store.reader() as (db, manifest):
            candidates = self.objects(db, policy)
            def matches(obj):
                for name, wanted in filters.items():
                    if name == "project":
                        if guid(wanted) not in set(obj["roots"]) & policy.projects:
                            return False
                    elif name == "type":
                        if obj["kind"] != wanted:
                            return False
                    else:
                        actual = [str(obj["fields"].get(f, {}).get(a, "")).casefold()
                                  for f in FILTER_FIELDS[name] for a in ("value", "label")]
                        if wanted.casefold() not in actual:
                            return False
                return True
            candidates = {k: v for k, v in candidates.items() if matches(v)}
            scores = defaultdict(float)
            reasons = defaultdict(set)
            excerpts = {}
            normalized = query.strip().casefold()
            for object_id, obj in candidates.items():
                exact = [obj["uuid"], object_id, obj["title"]]
                exact.extend(str(obj["fields"].get(f, {}).get("value", "")) for f in ("Code", "Number", "итлКодMantis", "итлСсылкаНаМантис"))
                if normalized in {x.casefold() for x in exact if x}:
                    scores[object_id] += 10
                    reasons[object_id].add("exact")
            tokens = re.findall(r"\w+", query, flags=re.UNICODE)[:40]
            if tokens:
                expression = " OR ".join('"' + t + '"' for t in tokens)
                rank = 0
                for row in db.execute("SELECT f.*,bm25(search_text) AS rank FROM search_text JOIN fragments f ON f.id=search_text.rowid WHERE search_text MATCH ? ORDER BY rank,f.id", (expression,)):
                    oid = row["object_id"]
                    if oid not in candidates:
                        continue
                    rank += 1
                    scores[oid] += 1 / (60 + rank)
                    reasons[oid].add("lexical")
                    excerpts.setdefault(oid, self.excerpt(row))
                    if rank >= 500:
                        break
            mode, cached, degradation = "lexical_exact", False, None
            if manifest["profile"] == self.settings.profile and candidates:
                try:
                    qv, cached = self.queries.get(query)
                    semantic = []
                    cursor = db.execute("SELECT * FROM fragments WHERE vector IS NOT NULL ORDER BY id")
                    while rows := cursor.fetchmany(256):
                        rows = [r for r in rows if r["object_id"] in candidates]
                        if not rows:
                            continue
                        matrix = np.stack([np.frombuffer(r["vector"], dtype=np.float32) for r in rows])
                        if matrix.shape[1] != self.settings.dimension:
                            raise SpprError("Stored vector dimension does not match the profile; rebuild semantic coverage.")
                        for score, row in zip(matrix @ qv, rows):
                            semantic.append((float(score), row))
                        semantic.sort(key=lambda pair: (-pair[0], pair[1]["id"]))
                        del semantic[500:]
                    for rank, (similarity, row) in enumerate(semantic, 1):
                        oid = row["object_id"]
                        scores[oid] += 1 / (60 + rank)
                        reasons[oid].add("semantic")
                        excerpts.setdefault(oid, self.excerpt(row))
                    mode = "hybrid"
                except SpprError as exc:
                    degradation = str(exc)
            elif manifest["profile"] != self.settings.profile:
                degradation = "Embedding profile changed; rebuild vectors before semantic search."
            ranked = sorted(scores, key=lambda k: (-scores[k], k))[:limit]
            hits = []
            for oid in ranked:
                item = self.summary(candidates[oid], policy)
                item.update({"match": sorted(reasons[oid]), "score": scores[oid], "excerpt": excerpts.get(oid),
                             "relationship": "возможно связано" if reasons[oid] == {"semantic"} else "search_match"})
                hits.append(item)
            return self.checked({**self.envelope(manifest, policy), "search_mode": mode,
                                 "query_vector_cached": cached, "degradation": degradation, "hits": hits,
                                 "exhaustive": False, "note": "Top-k search; use list_sppr_relations for stored relationships."}, policy)

    @staticmethod
    def excerpt(row):
        return {"text": row["text"][:700], "field": row["field"], "offset": row["offset"],
                "edge_id": row["edge_id"], "object_id": row["object_id"]}

    def read(self, object_id, cursor=None, limit=10, edge_id=None):
        self.limit(limit)
        split_key(object_id)
        policy = Policy.load(self.settings.policy)
        with self.store.reader() as (db, manifest):
            obj = self.objects(db, policy).get(object_id)
            if not obj:
                raise SpprError("Object is unavailable in the current corpus; search again or check the project policy.")
            fields = obj["fields"]
            if edge_id:
                row = db.execute("SELECT data FROM edges WHERE id=? AND source=?", (edge_id, object_id)).fetchone()
                if not row:
                    raise SpprError("Relation row is not available on this object.")
                fields = json.loads(row["data"])["fields"]
            context = digest(["read", object_id, edge_id, limit, manifest["generation"], policy.token])
            offset = self.cursor(cursor, context)
            units = []
            for name, record in sorted(fields.items()):
                value = record.get("value")
                if isinstance(value, str) and len(value) > 1800:
                    for pos in range(0, len(value), 1800):
                        units.append({"field": name, "state": record["state"], "value": value[pos:pos+1800],
                                      "offset": pos, "total_chars": len(value)})
                else:
                    units.append({"field": name, **record})
            page, used = [], 0
            for unit in units[offset:offset+limit]:
                size = len(canonical(unit))
                if page and used + size > 14000:
                    break
                page.append(unit)
                used += size
            end = offset + len(page)
            return self.checked({**self.envelope(manifest, policy), "object": self.summary(obj, policy),
                                 "edge_id": edge_id, "fields": page, "complete": end >= len(units),
                                 "cursor": self.next_cursor(end, context) if end < len(units) else None}, policy)

    def relations(self, object_id, direction="both", relation=None, cursor=None, limit=10, view="stored"):
        self.limit(limit)
        split_key(object_id)
        if direction not in ("both", "outgoing", "incoming"):
            raise SpprError("direction must be both, outgoing or incoming.")
        if view not in ("stored", "development"):
            raise SpprError("view must be stored or development.")
        if view == "development" and (not object_id.startswith(IDEA + ":") or direction != "both" or relation):
            raise SpprError("development view requires an idea ID, direction=both and no relation filter.")
        policy = Policy.load(self.settings.policy)
        with self.store.reader() as (db, manifest):
            objects = self.objects(db, policy)
            if object_id not in objects:
                raise SpprError("Object is outside the active corpus; search again under the current policy.")
            context = digest(["relations", object_id, direction, relation, limit, view, manifest["generation"], policy.token])
            offset = self.cursor(cursor, context)
            if view == "development":
                kinds = sorted(MEMBERSHIP | {PARENT})
                rows = db.execute("SELECT data FROM edges WHERE relation IN (?,?,?) ORDER BY id", kinds)
                records = development_context(object_id, objects, (json.loads(r["data"]) for r in rows))
                output = []
                for record in records[offset:offset+limit]:
                    item = dict(record)
                    for role in ("chtz", "developer_task", "related_tp"):
                        item[role] = self.summary(objects[record[role]], policy) if record[role] else None
                    evidence = list(dict.fromkeys(record["evidence"]))
                    item.update({"evidence": evidence[:20], "evidence_count": len(evidence),
                                 "evidence_complete": len(evidence) <= 20})
                    output.append(item)
                end = offset + len(output)
                return self.checked({**self.envelope(manifest, policy), "view": view, "contexts": output,
                                     "complete": end >= len(records), "scope": "role interpretation over currently indexed relationships",
                                     "cursor": self.next_cursor(end, context) if end < len(records) else None}, policy)
            selected = []
            for row in db.execute("SELECT data FROM edges WHERE source=? OR target=? ORDER BY id", (object_id, object_id)):
                edge = json.loads(row["data"])
                if edge["source"] not in objects:
                    continue
                if direction == "outgoing" and edge["source"] != object_id or direction == "incoming" and edge["target"] != object_id:
                    continue
                if relation and edge["relation"] != relation:
                    continue
                selected.append(edge)
            output = []
            for edge in selected[offset:offset+limit]:
                def endpoint(identifier):
                    if identifier in objects:
                        return self.summary(objects[identifier], policy)
                    kind, uuid = identifier.split(":", 1)
                    links = navigation(self.settings, kind, uuid) if kind in KINDS else None
                    state = edge.get("target_state", "outside_corpus_or_unavailable")
                    if state == "indexed":
                        state = "outside_corpus_or_unavailable"  # Policy may have revoked the cached target.
                    return {"id": identifier, "state": state, "links": links,
                            "link_notice": None if links else "Unsupported metadata type; no validated link."}
                preview = [{"field": name, "text": str(record.get("value") or "")[:240]}
                           for name, record in edge["fields"].items() if record.get("state") == "value"
                           and isinstance(record.get("value"), str) and not name.endswith(("_Key", "_Type"))][:3]
                output.append({"id": edge["id"], "relation": edge["relation"], "row": edge["row"],
                               "technical_id": edge.get("technical_id"), "correlation_id": edge.get("correlation_id"),
                               "source": endpoint(edge["source"]), "target": endpoint(edge["target"]),
                               "preview": preview, "read_text": {"object_id": edge["source"], "edge_id": edge["id"]}})
            end = offset + len(output)
            return self.checked({**self.envelope(manifest, policy), "relations": output,
                                 "complete": end >= len(selected), "scope": "indexed adjacent relationships",
                                 "cursor": self.next_cursor(end, context) if end < len(selected) else None}, policy)

    def status(self):
        policy = Policy.load(self.settings.policy)
        try:
            with self.store.reader() as (db, manifest):
                visible = self.objects(db, policy)
                result = {**self.envelope(manifest, policy), "state": "available", "visible_objects": len(visible)}
        except SpprError as exc:
            result = {"state": "unavailable", "reason": str(exc)}
        try:
            attempt = json.loads((self.settings.state / "attempt.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            attempt = None
        result.update({"projects": sorted(policy.projects), "last_attempt": attempt,
                       "schedule": {"mode": "nightly_reconciliation", "start": self.settings.night_start,
                                    "end": self.settings.night_end, "time_zone": self.settings.time_zone,
                                    "requires_open_user_session": True},
                       "protocol": "functional tool response", "query_cache_size": len(self.queries.values)})
        return self.checked(result, policy)
