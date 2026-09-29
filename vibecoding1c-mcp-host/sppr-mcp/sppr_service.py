"""Bounded retrieval over one immutable generation and a freshly read project policy."""
from __future__ import annotations

import base64
import hmac
import heapq
import json
import re
import secrets
import time
from collections import Counter, defaultdict, deque
from threading import Lock

from sppr_core import KINDS, Policy, SpprError, canonical, digest, navigation, split_key
from sppr_embeddings import QueryCache, QueryWaitTimeout
from sppr_links import IDEA, MEMBERSHIP, PARENT, development_context
from sppr_odata import HttpNetworkError, HttpStatusError
from sppr_store import Store
from sppr_retrieval import Graph, field_matches, field_units, identifiers, integer, page_items, select, strings
from sppr_vectors import VectorSearchCache


class SearchDiagnostics:
    """Bounded process-local timings and counts; never retains query text."""

    def __init__(self):
        self.lock = Lock()
        self.counts = Counter()
        self.fallbacks = Counter()
        self.uncached_ms = deque(maxlen=64)
        self.cached_ms = deque(maxlen=64)
        self.local_ms = deque(maxlen=64)

    def record(self, mode, cached, query_ms, local_ms, degradation_kind):
        with self.lock:
            self.counts["requests"] += 1
            self.counts["hybrid" if mode == "hybrid" else "lexical_only"] += 1
            if query_ms is not None:
                self.counts["query_cache_hits" if cached else "query_cache_misses"] += 1
                (self.cached_ms if cached else self.uncached_ms).append(query_ms)
            self.local_ms.append(local_ms)
            if degradation_kind:
                self.fallbacks[degradation_kind] += 1

    @staticmethod
    def latency(values):
        ordered = sorted(values)
        if not ordered:
            return {"samples": 0, "p95_ms": None, "max_ms": None}
        p95 = max(0, (95 * len(ordered) + 99) // 100 - 1)
        return {"samples": len(ordered), "p95_ms": ordered[p95], "max_ms": ordered[-1]}

    def snapshot(self, query_timeout):
        with self.lock:
            return {"query_timeout_seconds": query_timeout, "window": 64,
                    "counts": dict(self.counts), "fallbacks": dict(self.fallbacks),
                    "uncached_query_vector": self.latency(self.uncached_ms),
                    "cached_query_vector": self.latency(self.cached_ms),
                    "local_search": self.latency(self.local_ms)}


class Service:
    def __init__(self, settings, provider):
        self.settings = settings
        self.store = Store(settings)
        self.queries = QueryCache(settings, provider)
        self.vector_search = VectorSearchCache()
        self.search_diagnostics = SearchDiagnostics()
        self.objects_lock = Lock()
        self.objects_key = None
        self.objects_data = None
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
                "coverage": manifest["coverage"], "coverage_scope": "at collection publication before current policy filtering; current vectors in sppr_index_status",
                "profile_compatible": manifest["profile"] == self.settings.profile,
                "current_policy": policy.token}

    def objects(self, db, policy):
        corpus = next(row["file"] for row in db.execute("PRAGMA database_list") if row["name"] == "main")
        key = (corpus, policy.token)
        with self.objects_lock:
            if key == self.objects_key:
                return self.objects_data
            if policy.projects:
                placeholders = ",".join("?" for _ in policy.projects)
                sql = f"SELECT DISTINCT o.id,o.data FROM objects o JOIN roots r ON r.object_id=o.id WHERE r.project IN ({placeholders})"
                objects = {row["id"]: json.loads(row["data"]) for row in db.execute(sql, sorted(policy.projects))}
            else:
                objects = {}
            self.objects_key, self.objects_data = key, objects
            return objects

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

    def search(self, query, filters=None, limit=10, object_ids=None, fields=None):
        started = time.monotonic_ns()
        self.limit(limit)
        if not isinstance(query, str) or not query.strip() or len(query) > 4000:
            raise SpprError("Provide a nonempty query of at most 4000 characters.")
        object_ids, fields = identifiers(object_ids), strings(fields, "fields")
        policy = Policy.load(self.settings.policy)
        with self.store.reader() as (db, manifest):
            objects = self.objects(db, policy)
            candidates = select(objects, filters, policy.projects)
            if object_ids is not None:
                candidates = {k: v for k, v in candidates.items() if k in object_ids}
            # A realization belongs to the source TP row and is also searchable
            # when its indexed idea is selected. Preserve row provenance in hits.
            row_owners = {}
            if object_ids is not None:
                placeholders = ",".join("?" for _ in candidates)
                edges = (db.execute("SELECT id,source,target FROM edges WHERE target IN (" + placeholders + ") ORDER BY id",
                                    tuple(candidates)) if candidates else ())
                for row in edges:
                    if row["source"] in objects and row["target"] in candidates:
                        row_owners[row["id"]] = row["target"]
            def owner(row):
                if not field_matches(row["field"], fields):
                    return None
                oid = row["object_id"]
                return oid if oid in candidates else row_owners.get(row["edge_id"])
            scores = defaultdict(float)
            reasons = defaultdict(set)
            excerpts = {}
            normalized = query.strip().casefold()
            for object_id, obj in candidates.items():
                exact = [obj["uuid"], object_id] if fields is None else []
                if field_matches("title", fields):
                    exact.append(obj["title"])
                exact.extend(str(obj["fields"].get(f, {}).get("value", "")) for f in ("Code", "Number", "итлКодMantis", "итлСсылкаНаМантис") if field_matches(f, fields))
                if normalized in {x.casefold() for x in exact if x}:
                    scores[object_id] += 10
                    reasons[object_id].add("exact")
            setup_ms = (time.monotonic_ns() - started) // 1_000_000
            lexical_started = time.monotonic_ns()
            tokens = re.findall(r"\w+", query, flags=re.UNICODE)[:40]
            if tokens:
                distinct = list(dict.fromkeys(tokens))
                if len(distinct) > 1:
                    # An object containing every requested word in one indexed
                    # fragment must outrank partial OR/semantic matches. Keep
                    # the loose pass below for related and synonym results.
                    strict = " AND ".join('"' + t + '"' for t in distinct)
                    boosted = set()
                    examined = 0
                    for row in db.execute("SELECT f.*,bm25(search_text) AS rank FROM search_text JOIN fragments f ON f.id=search_text.rowid WHERE search_text MATCH ? ORDER BY rank,f.id", (strict,)):
                        oid = owner(row)
                        if oid is None:
                            continue
                        examined += 1
                        if oid not in boosted:
                            scores[oid] += 0.2
                            boosted.add(oid)
                            reasons[oid].add("lexical")
                            excerpts.setdefault(oid, self.excerpt(row))
                        if examined >= 500:
                            break
                expression = " OR ".join('"' + t + '"' for t in tokens)
                rank = 0
                for row in db.execute("SELECT f.*,bm25(search_text) AS rank FROM search_text JOIN fragments f ON f.id=search_text.rowid WHERE search_text MATCH ? ORDER BY rank,f.id", (expression,)):
                    oid = owner(row)
                    if oid is None:
                        continue
                    rank += 1
                    scores[oid] += 1 / (60 + rank)
                    reasons[oid].add("lexical")
                    excerpts.setdefault(oid, self.excerpt(row))
                    if rank >= 500:
                        break
            lexical_ms = (time.monotonic_ns() - lexical_started) // 1_000_000
            mode, cached, degradation = "lexical_exact", False, None
            query_ms, degradation_kind = None, None
            vector_cache_hit = None
            vector_prepare_ms = vector_score_ms = fragment_rank_ms = 0
            prepare_started = time.monotonic_ns()
            scope_sql, scope_args = "", []
            if 0 < len(candidates) + len(row_owners) <= 400:
                parts = []
                if candidates:
                    parts.append("f.object_id IN (" + ",".join("?" for _ in candidates) + ")")
                    scope_args.extend(candidates)
                if row_owners:
                    parts.append("f.edge_id IN (" + ",".join("?" for _ in row_owners) + ")")
                    scope_args.extend(row_owners)
                scope_sql = " AND (" + " OR ".join(parts) + ")"
            try:
                hashes, matrix, vector_cache_hit = self.vector_search.get(db, manifest, self.settings.dimension)
            except SpprError as exc:
                hashes, matrix = (), None
                degradation, degradation_kind = str(exc), "local_vector_index"
            available = set(hashes)
            fragment_sql = ("SELECT f.id,f.object_id,f.edge_id,f.field,f.offset,f.text,f.hash "
                            "FROM fragments f WHERE 1=1" + scope_sql + " ORDER BY f.id")
            has_vectors = bool(hashes) and any(
                row["hash"] in available and owner(row) is not None
                for row in db.execute(fragment_sql, scope_args))
            vector_prepare_ms = (time.monotonic_ns() - prepare_started) // 1_000_000
            if manifest["profile"] == self.settings.profile and candidates and has_vectors:
                phase = "embedding"
                try:
                    embedding_started = time.monotonic_ns()
                    try:
                        qv, cached = self.queries.get(query)
                    finally:
                        query_ms = (time.monotonic_ns() - embedding_started) // 1_000_000
                    phase = "ranking"
                    score_started = time.monotonic_ns()
                    similarities = dict(zip(hashes, (float(score) for score in matrix @ qv)))
                    vector_score_ms = (time.monotonic_ns() - score_started) // 1_000_000
                    rank_started = time.monotonic_ns()
                    semantic = []
                    for row in db.execute(fragment_sql, scope_args):
                        similarity = similarities.get(row["hash"])
                        if similarity is None or owner(row) is None:
                            continue
                        entry = (similarity, -row["id"], row)
                        if len(semantic) < 500:
                            heapq.heappush(semantic, entry)
                        elif entry[:2] > semantic[0][:2]:
                            heapq.heapreplace(semantic, entry)
                    for rank, (similarity, _, row) in enumerate(
                            sorted(semantic, key=lambda item: (-item[0], -item[1])), 1):
                        oid = owner(row)
                        scores[oid] += 1 / (60 + rank)
                        reasons[oid].add("semantic")
                        excerpts.setdefault(oid, self.excerpt(row))
                    fragment_rank_ms = (time.monotonic_ns() - rank_started) // 1_000_000
                    mode = "hybrid"
                except SpprError as exc:
                    degradation = str(exc)
                    if phase == "ranking":
                        degradation_kind = "local_vector_index"
                    elif isinstance(exc, HttpNetworkError):
                        degradation_kind = exc.category
                    elif isinstance(exc, HttpStatusError):
                        degradation_kind = f"http_{exc.status}"
                    elif isinstance(exc, QueryWaitTimeout):
                        degradation_kind = "shared_query_timeout"
                    else:
                        degradation_kind = "embedding_error"
            elif manifest["profile"] != self.settings.profile:
                degradation = "Embedding profile changed; rebuild vectors before semantic search."
                degradation_kind = "profile_mismatch"
            ranked = sorted(scores, key=lambda k: (-scores[k], k))[:limit]
            hits = []
            for oid in ranked:
                item = self.summary(candidates[oid], policy)
                item.update({"match": sorted(reasons[oid]), "score": scores[oid], "excerpt": excerpts.get(oid),
                             "relationship": "возможно связано" if reasons[oid] == {"semantic"} else "search_match"})
                hits.append(item)
            total_ms = (time.monotonic_ns() - started) // 1_000_000
            local_ms = max(0, total_ms - (query_ms or 0))
            result = self.checked({**self.envelope(manifest, policy), "search_mode": mode,
                                   "query_vector_cached": cached, "degradation": degradation,
                                   "degradation_kind": degradation_kind,
                                   "timing_ms": {"query_vector": query_ms, "local_search": local_ms, "total": total_ms,
                                                 "setup": setup_ms, "lexical": lexical_ms,
                                                 "vector_prepare": vector_prepare_ms,
                                                 "vector_score": vector_score_ms, "fragment_rank": fragment_rank_ms},
                                   "vector_cache_hit": vector_cache_hit,
                                   "hits": hits, "object_ids": object_ids, "fields": fields,
                                   "exhaustive": False, "note": "Top-k search; use list_sppr_relations for stored relationships."}, policy)
            self.search_diagnostics.record(mode, cached, query_ms, local_ms, degradation_kind)
            return result

    @staticmethod
    def excerpt(row):
        return {"text": row["text"][:700], "field": row["field"], "offset": row["offset"],
                "edge_id": row["edge_id"], "object_id": row["object_id"]}

    def read(self, object_id, cursor=None, limit=10, edge_id=None, fields=None):
        self.limit(limit)
        batch = isinstance(object_id, list)
        ids = identifiers(object_id if batch else [object_id], 20)
        fields = strings(fields, "fields")
        if batch and edge_id:
            raise SpprError("edge_id requires a single source object_id; use read_text from a relation.")
        policy = Policy.load(self.settings.policy)
        with self.store.reader() as (db, manifest):
            objects = self.objects(db, policy)
            if any(oid not in objects for oid in ids):
                raise SpprError("Object is unavailable in the current corpus; search again or check the project policy.")
            obj = objects[ids[0]]
            records = obj["fields"]
            if edge_id:
                row = db.execute("SELECT data FROM edges WHERE id=? AND source=?", (edge_id, object_id)).fetchone()
                if not row:
                    raise SpprError("Relation row is not available on this object.")
                records = json.loads(row["data"])["fields"]
            context = digest(["read", ids, batch, edge_id, fields, limit, manifest["generation"], policy.token])
            offset = self.cursor(cursor, context)
            def batch_items():
                for oid in ids:
                    yield {"kind": "object", "object": self.compact(objects[oid], policy)}
                    for unit in field_units(objects[oid]["fields"], fields):
                        yield {"kind": "field", "object_id": oid, **unit}
            page, complete = page_items(batch_items() if batch else field_units(records, fields), offset, limit)
            end = offset + len(page)
            result = {"items": page, "object_ids": ids} if batch else {
                "object": self.summary(obj, policy), "edge_id": edge_id, "fields": page}
            return self.checked({**self.envelope(manifest, policy), **result, "selected_fields": fields,
                                 "complete": complete, "cursor": None if complete else self.next_cursor(end, context)}, policy)

    def compact(self, obj, policy):
        summary = self.summary(obj, policy)
        return {k: summary[k] for k in ("id", "type", "title", "title_truncated", "tp_role", "links")}

    def item_page(self, items, parameters, manifest, policy, cursor, limit):
        self.limit(limit)
        context = digest([parameters, limit, manifest["generation"], policy.token])
        offset = self.cursor(cursor, context)
        page, complete = page_items(items, offset, limit)
        return {"items": page, "page_complete": complete,
                "cursor": None if complete else self.next_cursor(offset + len(page), context)}

    def list_objects(self, filters=None, cursor=None, limit=10):
        policy = Policy.load(self.settings.policy)
        with self.store.reader() as (db, manifest):
            objects = select(self.objects(db, policy), filters, policy.projects)
            items = (self.compact(objects[k], policy) for k in sorted(objects))
            page = self.item_page(items, ["list", filters], manifest, policy, cursor, limit)
            return self.checked({**self.envelope(manifest, policy), **page, "total": len(objects),
                                 "complete": page["page_complete"], "scope": "all indexed objects matching exact filters"}, policy)

    @staticmethod
    def edge_item(edge):
        return {"kind": "relation", **{k: edge.get(k) for k in
                ("id", "source", "target", "relation", "row", "technical_id", "correlation_id")},
                "read_text": {"object_id": edge["source"], "edge_id": edge["id"]}}

    @staticmethod
    def role_edges(db, objects):
        kinds = sorted(MEMBERSHIP | {PARENT})
        return [dict(r) for r in db.execute(
            "SELECT id,source,target,relation FROM edges WHERE relation IN (?,?,?) ORDER BY id", kinds)
            if r["source"] in objects]

    def context(self, object_ids, depth=2, direction="both", relations=None, max_objects=50,
                fields=None, cursor=None, limit=10):
        ids = identifiers(object_ids, 20)
        if ids is None:
            raise SpprError("Provide at least one seed object_id.")
        fields = strings(fields, "fields")
        policy = Policy.load(self.settings.policy)
        with self.store.reader() as (db, manifest):
            objects = self.objects(db, policy)
            if any(oid not in objects for oid in ids):
                raise SpprError("Seed object is outside the active corpus; search again under the current policy.")
            graph = Graph(db, objects, direction, relations)
            walk = graph.walk(ids, depth, max_objects)
            # Role interpretation must see all indexed memberships, not infer
            # same_tp from a traversal that stopped before a separate task.
            roles = self.role_edges(db, objects)
            def items():
                for oid, level in walk["distance"].items():
                    parent = walk["via"][oid]
                    yield {"kind": "object", "object": self.compact(objects[oid], policy), "depth": level,
                           "via": {"object_id": parent[0], "edge_id": parent[1]} if parent else None}
                    if fields is not None:
                        for unit in field_units(objects[oid]["fields"], fields):
                            yield {"kind": "field", "object_id": oid, **unit}
                    if objects[oid]["kind"] == IDEA:
                        for role in development_context(oid, objects, roles):
                            evidence = list(dict.fromkeys(role["evidence"]))
                            yield {"kind": "development", "object_id": oid, **role,
                                   "evidence": evidence[:20], "evidence_complete": len(evidence) <= 20,
                                   "scope": "all indexed development relationships",
                                   "read_more": {"object_id": oid, "view": "development"}}
                terminals = set()
                for edge in walk["edges"].values():
                    yield self.edge_item(edge)
                    for endpoint in (edge["source"], edge["target"]):
                        if endpoint not in walk["distance"] and endpoint not in terminals:
                            terminals.add(endpoint)
                            kind, uuid = endpoint.split(":", 1)
                            state = "traversal_limit" if endpoint in objects else edge.get("target_state", "outside_corpus_or_unavailable")
                            if state == "indexed":
                                state = "outside_corpus_or_unavailable"
                            yield {"kind": "boundary", "id": endpoint, "state": state,
                                   "links": navigation(self.settings, kind, uuid) if kind in KINDS else None}
                    if fields is not None:
                        for unit in field_units(edge["fields"], fields):
                            yield {"kind": "field", "object_id": edge["source"], "edge_id": edge["id"], **unit}
                for oid in walk["frontier"]:
                    yield {"kind": "frontier", "object_id": oid,
                           "continue_from": {"object_ids": [oid], "direction": direction, "relations": relations}}
            page = self.item_page(items(), ["context", ids, depth, direction, relations, max_objects, fields],
                                  manifest, policy, cursor, limit)
            return self.checked({**self.envelope(manifest, policy), **page,
                "object_count": len(walk["distance"]), "relation_count": len(walk["edges"]),
                "traversal_complete": not walk["stop_reasons"], "stop_reasons": walk["stop_reasons"],
                "complete": page["page_complete"] and not walk["stop_reasons"],
                "examined_edges": walk["examined_edges"], "selected_fields": fields,
                "scope": "reachable indexed objects under requested direction and relations; outside-corpus endpoints are terminal",
                "continuation": "Follow cursor for this traversal; for stop_reasons increase bounds or continue from frontier objects."}, policy)

    def paths(self, source_id, target_id, depth=4, direction="both", relations=None,
              max_objects=200, max_paths=5, cursor=None, limit=10):
        identifiers([source_id, target_id])
        integer(max_paths, "max_paths", 1, 20)
        policy = Policy.load(self.settings.policy)
        with self.store.reader() as (db, manifest):
            objects = self.objects(db, policy)
            if source_id not in objects or target_id not in objects:
                raise SpprError("Path endpoint is outside the active corpus; search again under the current policy.")
            graph = Graph(db, objects, direction, relations)
            walk = graph.walk([source_id], depth, max_objects, target_id)
            paths, more = graph.shortest_paths(walk, source_id, target_id, max_paths)
            stops = walk["stop_reasons"] + (["max_paths"] if more else [])
            def items():
                for number, path in enumerate(paths, 1):
                    yield {"kind": "path", "number": number, **path}
                used_nodes = sorted({oid for path in paths for oid in path["object_ids"]})
                used_edges = sorted({eid for path in paths for eid in path["edge_ids"]})
                for oid in used_nodes:
                    yield {"kind": "object", "object": self.compact(objects[oid], policy)}
                for eid in used_edges:
                    yield self.edge_item(walk["edges"][eid])
            page = self.item_page(items(), ["paths", source_id, target_id, depth, direction, relations, max_objects, max_paths],
                                  manifest, policy, cursor, limit)
            return self.checked({**self.envelope(manifest, policy), **page, "found": bool(paths),
                "path_count": len(paths), "stop_reasons": stops, "complete": page["page_complete"] and not stops,
                "scope": "shortest stored paths within requested bounds; semantic similarity is not a link",
                "continuation": "Follow cursor; increase depth/max_objects/max_paths for a reported stop reason."}, policy)

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
                records = development_context(object_id, objects, self.role_edges(db, objects))
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
                result["semantic_progress"] = self.store.semantic_progress(db, manifest)
                result["semantic_complete"] = result["semantic_progress"]["pending"] == 0
        except SpprError as exc:
            result = {"state": "unavailable", "reason": str(exc)}
        try:
            attempt = json.loads((self.settings.state / "attempt.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            attempt = None
        try:
            embedding_attempt = json.loads((self.settings.state / "embed_attempt.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            embedding_attempt = None
        result.update({"projects": sorted(policy.projects), "last_attempt": attempt,
                       "last_embedding_attempt": embedding_attempt,
                       "schedule": {"mode": "nightly_reconciliation", "start": self.settings.night_start,
                                    "end": self.settings.night_end, "time_zone": self.settings.time_zone,
                                    "requires_open_user_session": True},
                       "embedding_schedule": {"mode": "periodic", "interval_minutes": self.settings.embedding_interval_minutes,
                                              "max_in_flight": self.settings.embedding_workers,
                                              "requires_open_user_session": True},
                       "protocol": "functional tool response", "query_cache_size": len(self.queries.values),
                       "search_diagnostics": self.search_diagnostics.snapshot(self.settings.query_timeout)})
        return self.checked(result, policy)
