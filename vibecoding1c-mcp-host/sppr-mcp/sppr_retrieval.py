"""Stateless selectors, bounded field pages and graph walks within one reader snapshot."""
from collections import defaultdict, deque
from itertools import islice
import json

from sppr_core import FILTER_FIELDS, KINDS, SpprError, canonical, guid, split_key


def integer(value, name, low, high):
    if type(value) is not int or not low <= value <= high:
        raise SpprError(f"{name} must be between {low} and {high}.")
    return value


def strings(values, name, maximum=30):
    if values is None:
        return None
    if not isinstance(values, list) or not 1 <= len(values) <= maximum or any(
            not isinstance(v, str) or not v or len(v) > 400 for v in values):
        raise SpprError(f"{name} must be a nonempty list of at most {maximum} names/IDs.")
    return sorted(set(values))


def identifiers(values, maximum=200):
    values = strings(values, "object_ids", maximum)
    for value in values or []:
        split_key(value)
    return values


def field_matches(name, fields):
    # A trailing slash selects a field family, e.g. additional attributes.
    return fields is None or any(name == f or f.endswith("/") and name.startswith(f) for f in fields)


def select(objects, filters=None, projects=None):
    filters = {} if filters is None else filters
    if not isinstance(filters, dict) or set(filters) - (set(FILTER_FIELDS) | {"project", "type"}):
        raise SpprError("Supported filters: project, type, status, developer, tester, business_type, sprint.")
    if any(not isinstance(v, str) or len(v) > 500 for v in filters.values()):
        raise SpprError("Filter values must be strings of at most 500 characters.")
    if "type" in filters and filters["type"] not in KINDS:
        raise SpprError("Unsupported metadata type filter.")
    project = guid(filters["project"]) if "project" in filters else None
    if project and projects is not None and project not in projects:
        return {}

    def matches(obj):
        for name, wanted in filters.items():
            if name == "project":
                if project not in obj["roots"]:
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
    return {k: v for k, v in objects.items() if matches(v)}


def field_units(records, fields=None):
    for name, record in sorted(records.items()):
        if not field_matches(name, fields):
            continue
        value = record.get("value")
        metadata = {k: v for k, v in record.items() if k != "value"}
        if len(canonical(metadata).encode("utf-8")) > 4000:
            # Preserve unusually large labels/metadata without an oversized single item.
            text = canonical(record)
            for pos in range(0, len(text), 1200):
                yield {"field": name, "encoding": "record_json", "text": text[pos:pos+1200],
                       "offset": pos, "total_chars": len(text)}
        elif isinstance(value, str) and len(value) > 1800:
            for pos in range(0, len(value), 1800):
                yield {"field": name, **metadata, "value": value[pos:pos+1800],
                       "offset": pos, "total_chars": len(value)}
        else:
            yield {"field": name, **record}


def page_items(items, offset, limit, budget=20000):
    page, size = [], 0
    for item in islice(items, offset, None):
        count = len(canonical(item).encode("utf-8"))
        if page and (len(page) >= limit or size + count > budget):
            return page, False
        page.append(item)
        size += count
    return page, True


class Graph:
    """Policy-filtered adjacency; no provider, source access, cache or durable state."""
    EDGE_BUDGET = 5000

    def __init__(self, db, objects, direction="both", relations=None):
        if direction not in ("both", "outgoing", "incoming"):
            raise SpprError("direction must be both, outgoing or incoming.")
        self.db, self.objects, self.direction = db, objects, direction
        self.relations = strings(relations, "relations")

    def adjacent(self, identifier):
        clause, args = {"both": ("(source=? OR target=?)", [identifier, identifier]),
                        "outgoing": ("source=?", [identifier]),
                        "incoming": ("target=?", [identifier])}[self.direction]
        if self.relations:
            clause += " AND relation IN (" + ",".join("?" for _ in self.relations) + ")"
            args += self.relations
        for row in self.db.execute("SELECT data FROM edges WHERE " + clause + " ORDER BY id", args):
            yield json.loads(row["data"])

    def walk(self, seeds, depth, max_objects, target=None):
        integer(depth, "depth", 0, 6)
        integer(max_objects, "max_objects", len(seeds), 200)
        distance = dict.fromkeys(seeds, 0)
        via = dict.fromkeys(seeds)
        queue, edges, stops, frontier = deque(seeds), {}, set(), set()
        examined, target_depth = 0, 0 if target in distance else None
        while queue:
            current = queue.popleft()
            level = distance[current]
            if target_depth is not None and level >= target_depth:
                continue
            for edge in self.adjacent(current):
                examined += 1
                if examined > self.EDGE_BUDGET:
                    stops.add("edge_budget")
                    frontier.add(current)
                    queue.clear()
                    break
                if edge["source"] not in self.objects:
                    continue
                other = edge["target"] if edge["source"] == current else edge["source"]
                if level >= depth:
                    if other in distance:
                        edges[edge["id"]] = edge
                    if other in self.objects and other not in distance:
                        stops.add("depth")
                        frontier.add(current)
                    continue
                edges[edge["id"]] = edge
                if other not in self.objects or other in distance:
                    continue
                if len(distance) >= max_objects:
                    stops.add("max_objects")
                    frontier.add(current)
                    continue
                distance[other], via[other] = level + 1, (current, edge["id"])
                queue.append(other)
                if other == target:
                    target_depth = level + 1
        return {"distance": distance, "via": via, "edges": edges, "stop_reasons": sorted(stops),
                "frontier": sorted(frontier), "examined_edges": min(examined, self.EDGE_BUDGET)}

    def shortest_paths(self, walk, source, target, maximum):
        if target not in walk["distance"]:
            return [], False
        parents = defaultdict(list)
        distance = walk["distance"]
        for edge in walk["edges"].values():
            a, b = edge["source"], edge["target"]
            if a in distance and b in distance:
                if self.direction != "incoming" and distance[a] + 1 == distance[b]:
                    parents[b].append((a, edge["id"]))
                if self.direction != "outgoing" and distance[b] + 1 == distance[a]:
                    parents[a].append((b, edge["id"]))
        def paths(node):
            if node == source:
                yield {"object_ids": [source], "edge_ids": []}
            else:
                for parent, edge_id in sorted(parents[node]):
                    for path in paths(parent):
                        yield {"object_ids": path["object_ids"] + [node], "edge_ids": path["edge_ids"] + [edge_id]}
        result = list(islice(paths(target), maximum + 1))
        return result[:maximum], len(result) > maximum
