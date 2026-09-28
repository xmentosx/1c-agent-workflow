"""Projected, read-only OData collection. Source eligibility precedes business reads."""
from __future__ import annotations

import base64
import copy
import json
import time
from collections import deque
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

from sppr_core import (BUSINESS_FIELDS, IDENTITY, KINDS, LOOKUPS, POLYMORPHIC_FIELDS, PROCESS, RICH_FIELDS,
                       ROW_FIELDS, SHARED, STEP, ZERO, Policy, SpprError, digest,
                       fields_from, guid, key, now, reference_type, safe_xml)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Http:
    def __init__(self, timeout=30, max_bytes=16 * 1024 * 1024, before=lambda: None):
        self.timeout, self.max_bytes, self.before = timeout, max_bytes, before
        self.opener = build_opener(NoRedirect())
        self.requests = self.bytes = 0

    def request(self, url, *, headers=None, body=None):
        for attempt in range(3):
            self.before()
            try:
                self.requests += 1
                req = Request(url, data=body, headers=headers or {}, method="GET" if body is None else "POST")
                with self.opener.open(req, timeout=self.timeout) as response:
                    data = response.read(self.max_bytes + 1)
                    self.bytes += len(data)
                    if len(data) > self.max_bytes:
                        raise SpprError("HTTP response exceeds limit; reduce page size or review the affected source field.")
                    return data
            except HTTPError as exc:
                code = exc.code
                exc.close()
                if code not in (429, 502, 503, 504) or attempt == 2:
                    raise SpprError(f"HTTP {code}; verify endpoint/access or retry later. Remote body redacted.") from None
            except (URLError, TimeoutError, OSError):
                if attempt == 2:
                    raise SpprError("Network request failed; verify connectivity and retry. Details redacted.") from None
            time.sleep(0.25 * (attempt + 1))
        raise SpprError("Request failed.")


class Schema:
    def __init__(self, xml):
        root = safe_xml(xml)
        self.properties, self.refs = {}, {}
        associations = {}
        for item in root.iter():
            if item.tag.rsplit("}", 1)[-1] == "Association":
                associations[item.attrib["Name"]] = {
                    end.attrib["Role"]: end.attrib["Type"].split(".")[-1] for end in item
                    if end.tag.rsplit("}", 1)[-1] == "End"}
        for entity in root.iter():
            if entity.tag.rsplit("}", 1)[-1] != "EntityType":
                continue
            name = entity.attrib["Name"]
            self.properties[name], self.refs[name] = {}, {}
            for child in entity:
                tag = child.tag.rsplit("}", 1)[-1]
                if tag == "Property":
                    self.properties[name][child.attrib["Name"]] = child.attrib["Type"]
                elif tag == "NavigationProperty":
                    association = child.attrib["Relationship"].split(".")[-1]
                    target = associations.get(association, {}).get(child.attrib["ToRole"])
                    if target:
                        self.refs[name][child.attrib["Name"] + "_Key"] = target
        for kind, contract in KINDS.items():
            required = {"Ref_Key", "DataVersion", "DeletionMark"}
            if contract.owner:
                required.add(contract.owner)
            if not required.issubset(self.properties.get(kind, {})):
                raise SpprError(f"OData schema does not cover required identity/ownership of {kind}; check publication.")

    def projection(self, entity, row=False):
        allowed = (ROW_FIELDS if row else BUSINESS_FIELDS | IDENTITY).copy()
        for name in RICH_FIELDS:
            allowed.update((name + "_Base64Data", name + "_Type"))
        return sorted(n for n, t in self.properties.get(entity, {}).items()
                      if n in allowed and t.startswith("Edm.") and t != "Edm.Stream")

    def references(self, entity, raw):
        for name, target in self.refs.get(entity, {}).items():
            if name in raw and raw[name] and raw[name] != ZERO:
                yield name, target, guid(raw[name])
        for name in sorted(POLYMORPHIC_FIELDS):
            target = reference_type(raw.get(name + "_Type"))
            if target and raw.get(name) and raw[name] != ZERO:
                yield name, target, guid(raw[name])


class OData:
    def __init__(self, settings, username, password, before=lambda: None):
        self.settings = settings
        self.http = Http(settings.timeout, settings.max_response_bytes, before)
        token = base64.b64encode((username + ":" + password).encode("utf-8")).decode("ascii")
        self.headers = {"Authorization": "Basic " + token, "Accept": "application/json"}
        self.schema = Schema(self.http.request(settings.odata_url + "$metadata", headers=self.headers))

    def get(self, entity, params, identifier=None):
        if entity not in self.schema.properties:
            raise SpprError("Unknown OData entity; refresh the supported schema mapping.")
        path = quote(entity, safe="_")
        if identifier:
            path += "(guid'" + guid(identifier) + "')"
        url = self.settings.odata_url + path + "?" + urlencode({"$format": "json", **params})
        try:
            return json.loads(self.http.request(url, headers=self.headers).decode("utf-8-sig"))
        except (ValueError, UnicodeError):
            raise SpprError("OData returned invalid JSON; verify the publication.") from None

    def pages(self, entity, fields, where, order):
        seen = set()
        offset = 0
        while True:
            data = self.get(entity, {"$select": ",".join(fields), "$filter": where,
                                     "$orderby": order, "$top": self.settings.page_size, "$skip": offset})
            rows = data.get("value")
            if not isinstance(rows, list):
                raise SpprError("OData page has no value array; previous generation retained.")
            for row in rows:
                marker = (row.get("Ref_Key"), row.get("LineNumber"))
                if marker in seen:
                    raise SpprError("OData pagination repeated a key; retry collection in a stable source window.")
                seen.add(marker)
                if len(seen) > self.settings.max_objects:
                    raise SpprError("Collection limit reached; review scope and raise the explicit limit if appropriate.")
                yield row
            if len(rows) < self.settings.page_size:
                break
            offset += len(rows)

    def inventory(self, kind, owner):
        column = KINDS[kind].owner
        fields = ["Ref_Key", "DataVersion", "DeletionMark", column]
        where = f"{column} eq guid'{guid(owner)}' and DeletionMark eq false"
        for row in self.pages(kind, fields, where, "Ref_Key"):
            if guid(row.get(column)) != owner or row.get("DeletionMark") is not False:
                raise SpprError("Source ignored the project filter; collection stopped before business reads.")
            yield row

    def header(self, kind, identifier):
        fields = ["Ref_Key", "DataVersion", "DeletionMark"]
        if KINDS[kind].owner:
            fields.append(KINDS[kind].owner)
        return self.read(kind, identifier, fields)

    def read_scoped(self, kind, identifier, fields, header):
        owner = KINDS[kind].owner
        if not owner:
            return self.read(kind, identifier, fields)
        version = str(header["DataVersion"]).replace("'", "''")
        where = (f"Ref_Key eq guid'{guid(identifier)}' and {owner} eq guid'{guid(header[owner])}' "
                 f"and DeletionMark eq false and DataVersion eq '{version}'")
        data = self.get(kind, {"$select": ",".join(fields), "$filter": where, "$top": 2})
        rows = data.get("value", [])
        if len(rows) != 1 or guid(rows[0].get(owner)) != guid(header[owner]):
            raise SpprError("Object ownership/version changed; discard this collection and retry.")
        return {name: rows[0][name] for name in fields if name in rows[0]}

    def read(self, kind, identifier, fields):
        raw = self.get(kind, {"$select": ",".join(fields)}, identifier)
        # Ignore unsolicited fields even if a misconfigured service sends them.
        return {name: raw[name] for name in fields if name in raw}

    def table(self, kind, identifier, name):
        entity = kind + "_" + name
        fields = self.schema.projection(entity, row=True)
        if not {"Ref_Key", "LineNumber"}.issubset(fields):
            raise SpprError(f"Required table {entity} is not published; extend the OData publication.")
        rows = []
        for raw in self.pages(entity, fields, f"Ref_Key eq guid'{guid(identifier)}'", "LineNumber"):
            if guid(raw.get("Ref_Key")) != identifier:
                raise SpprError("Source ignored a table-owner filter; collection stopped.")
            rows.append({n: raw[n] for n in fields if n in raw})
        return rows


class Collection:
    def __init__(self, objects, edges, started, finished, coverage):
        self.objects, self.edges = objects, edges
        self.started, self.finished, self.coverage = started, finished, coverage


def collect(source, settings, policy, previous=None):
    """Two complete inventories reject unstable scans; table rows are read nightly.

    DataVersion is not assumed to cover table changes until live evidence exists.
    Version equality reuses only scalar projections, never skips table reads.
    """
    started = now()
    clock_started = time.monotonic()
    previous = previous or {}
    objects, edges, lookup_cache = {}, [], {}
    coverage = {"unreadable_fields": 0, "unsupported_references": 0, "types": {}}

    def check():
        policy.unchanged(settings.policy)

    def inventory():
        result = {}
        for kind, contract in KINDS.items():
            if kind in SHARED or kind == STEP:
                continue
            for project in sorted(policy.projects):
                check()
                for row in source.inventory(kind, project):
                    result[key(kind, row["Ref_Key"])] = (row, project)
                    if len(result) > settings.max_objects:
                        raise SpprError("Corpus exceeds max_objects; review scope before retrying.")
        processes = [(identifier, row, project) for identifier, (row, project) in result.items()
                     if identifier.startswith(PROCESS + ":")]
        for _, process, project in processes:
            for row in source.inventory(STEP, guid(process["Ref_Key"])):
                result[key(STEP, row["Ref_Key"])] = (row, project)
                if len(result) > settings.max_objects:
                    raise SpprError("Corpus exceeds max_objects; review scope before retrying.")
        if len(result) > settings.max_objects:
            raise SpprError("Corpus exceeds max_objects; review scope before retrying.")
        return result

    initial = inventory()

    def lookup(kind, identifier):
        marker = kind + ":" + identifier
        if marker not in lookup_cache:
            check()
            # Addressed labels/type discriminators cannot recursively expand a dictionary.
            allowed = ["Ref_Key", "Description", "DataVersion", "DeletionMark"]
            if kind == "Catalog_итлТипыТП":
                allowed.append("СрезТП")
            if kind == "ChartOfCharacteristicTypes_ДополнительныеРеквизитыИСведения":
                allowed.append("Заголовок")
            fields = [n for n in allowed
                      if n in source.schema.properties.get(kind, {})]
            if "Description" not in fields:
                return None
            raw = source.read(kind, identifier, fields)
            lookup_cache[marker] = {} if raw.get("DeletionMark") else {
                "label": raw.get("Заголовок") or raw.get("Description"), "tp_role": raw.get("СрезТП")}
        return lookup_cache[marker]

    def add_edges(obj, entity, raw, prefix="", row_number=None):
        row_fields = fields_from(raw, source.schema.projection(entity, row=True)) if prefix else {}
        technical_id = raw.get("ТехническийИдентификатор_Key")
        technical_id = guid(technical_id) if technical_id and technical_id != ZERO else None
        for name, kind, identifier in source.schema.references(entity, raw):
            if name in ("Owner_Key", "Проект_Key", "ТехническийИдентификатор_Key"):
                continue
            if kind in LOOKUPS:
                details = lookup(kind, identifier) or {}
                destination = row_fields if prefix else obj["fields"]
                if name in destination:
                    destination[name]["label"] = details.get("label")
                if not prefix and obj["kind"] == "Catalog_ТехническиеПроекты" and name == "итлТип_Key":
                    obj["tp_role"] = details.get("tp_role")
                    obj["fields"]["итлТип_Key/СрезТП"] = {
                        "state": "value" if obj["tp_role"] else "unavailable", "value": obj["tp_role"]}
                continue
            if kind not in KINDS:
                coverage["unsupported_references"] += 1
            target = kind + ":" + identifier
            relation = prefix + name
            correlation = digest([sorted([obj["id"], target]), technical_id]) if technical_id and {
                obj["kind"], kind} == {"Catalog_Идеи", STEP} else None
            edges.append({"id": digest([obj["id"], relation, technical_id or row_number, target]),
                          "source": obj["id"], "target": target, "relation": relation,
                          "row": row_number, "fields": row_fields,
                          "technical_id": technical_id, "correlation_id": correlation,
                          "supported": kind in KINDS})
        return row_fields

    def load_object(kind, identifier, header, project):
        check()
        object_id = key(kind, identifier)
        fresh_header = source.header(kind, identifier)
        if fresh_header != header:
            raise SpprError("Source membership/version changed before read; retry collection.")
        if fresh_header.get("DeletionMark"):
            raise SpprError("Source deletion changed during collection; retry.")
        columns = source.schema.projection(kind)
        old = previous.get(object_id, {})
        if old.get("version") == header["DataVersion"] and old.get("projection") == columns:
            raw = copy.deepcopy(old["raw"])
        else:
            raw = source.read_scoped(kind, identifier, columns, header)
        # Table reads are deliberately independent of scalar DataVersion reuse.
        tables = {name: source.table(kind, identifier, name) for name in KINDS[kind].tables}
        if source.header(kind, identifier) != fresh_header:
            raise SpprError("Object changed while reading its fields/rows; retry collection.")
        title = raw.get("Description") or " ".join(str(raw.get(x) or "") for x in ("Number", "Date")).strip() or identifier
        obj = {"id": object_id, "kind": kind, "uuid": identifier, "project": project,
               "roots": [project] if project else [], "provenance": {},
               "version": header["DataVersion"], "title": title, "is_folder": bool(raw.get("IsFolder")),
               "fields": fields_from(raw, columns), "raw": raw, "projection": columns,
               "tables": tables, "observed_at": now()}
        objects[object_id] = obj
        add_edges(obj, kind, raw)
        for table, rows in tables.items():
            for row in rows:
                edge_count = len(edges)
                row_fields = add_edges(obj, kind + "_" + table, row, table + "/", row["LineNumber"])
                if len(edges) == edge_count or table == "ДополнительныеРеквизиты":
                    # A textual requirement can have an empty reference. Keep it readable
                    # and searchable on the parent without inventing a relationship.
                    obj["fields"].update({f"{table}/{row['LineNumber']}/{name}": value
                                          for name, value in row_fields.items()
                                          if value["state"] != "not_applicable"})
        return obj

    for object_id, (header, project) in initial.items():
        kind, identifier = object_id.split(":", 1)
        load_object(kind, identifier, header, project)

    # Propagate one reproducible path per project to shared content, without reverse traversal.
    pending = deque((edge["target"], objects[edge["source"]]["project"], [edge["source"], edge["id"]])
                    for edge in edges if edge["target"].split(":", 1)[0] in SHARED)
    visited = set()
    while pending:
        object_id, project, path = pending.popleft()
        if (object_id, project) in visited:
            continue
        visited.add((object_id, project))
        if len(objects) >= settings.max_objects:
            raise SpprError("Shared corpus exceeds max_objects; review scope before retrying.")
        kind, identifier = object_id.split(":", 1)
        if object_id not in objects:
            check()
            header = source.header(kind, identifier)
            if header.get("DeletionMark"):
                continue
            load_object(kind, identifier, header, None)
        obj = objects[object_id]
        obj["roots"] = sorted(set(obj["roots"]) | {project})
        obj["provenance"][project] = path
        for edge in edges:
            if edge["source"] == object_id and edge["target"].split(":", 1)[0] in SHARED:
                pending.append((edge["target"], project, path + [object_id, edge["id"]]))

    # Re-enumeration catches offset pagination movement, additions, removals and scalar changes.
    if inventory() != initial:
        raise SpprError("Source inventory changed during collection; previous generation retained. Retry next window.")
    check()
    if len({edge["id"] for edge in edges}) != len(edges):
        raise SpprError("Duplicate relationship identity; correct duplicate technical row identifiers in SPPR and retry collection.")
    for obj in objects.values():
        coverage["types"][obj["kind"]] = coverage["types"].get(obj["kind"], 0) + 1
        coverage["unreadable_fields"] += sum(f["state"] == "unreadable" for f in obj["fields"].values())
    for edge in edges:
        coverage["unreadable_fields"] += sum(f["state"] == "unreadable" for f in edge["fields"].values())
        edge["target_state"] = "indexed" if edge["target"] in objects else "outside_corpus_or_unavailable"
    if hasattr(source, "http"):
        coverage.update({"odata_requests": source.http.requests, "odata_response_bytes": source.http.bytes})
    coverage["collection_seconds"] = round(time.monotonic() - clock_started, 3)
    return Collection(objects, edges, started, now(), coverage)
