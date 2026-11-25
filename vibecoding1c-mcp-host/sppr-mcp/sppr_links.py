"""Explain TP roles from explicit source links, never from names or similarity."""
from collections import defaultdict

TP = "Catalog_ТехническиеПроекты"
IDEA = "Catalog_Идеи"
MEMBERSHIP = {"ИдеиИОшибки/Идея", "ИдеиИОшибки/Идея_Key"}
PARENT = "итлРодитель_Key"
CHTZ = "ЧТЗ"
DEVELOPER = "ЗадачаРазработчику"


def development_context(idea_id, objects, edges):
    """objects is already filtered by the current policy; omitted parents stay unknown."""
    members, parents = defaultdict(list), defaultdict(list)
    for edge in edges:
        source = objects.get(edge["source"])
        if not source or source["kind"] != TP:
            continue
        if edge["relation"] in MEMBERSHIP and edge["target"] == idea_id:
            members[edge["source"]].append(edge["id"])
        elif edge["relation"] == PARENT:
            parents[edge["source"]].append(edge)

    def find_chtz(identifier):
        visited, evidence = set(), []
        while identifier not in visited:
            visited.add(identifier)
            links = parents.get(identifier, [])
            if len(links) != 1:
                return None, evidence, "parent_missing" if not links else "multiple_parents"
            edge = links[0]
            evidence.append(edge["id"])
            identifier = edge["target"]
            parent = objects.get(identifier)
            if not parent or parent["kind"] != TP:
                return None, evidence, "parent_outside_corpus_or_unavailable"
            if parent.get("tp_role") == CHTZ:
                return identifier, evidence, None
        return None, evidence, "parent_cycle"

    records, resolved_chtz, uncertain = [], set(), False
    for identifier, evidence in sorted(members.items()):
        role = objects[identifier].get("tp_role")
        if role == CHTZ:
            continue
        if role != DEVELOPER:
            uncertain = True
            records.append({"mode": "unresolved", "chtz": None, "developer_task": None,
                            "related_tp": identifier, "evidence": evidence,
                            "rule": "source_type_slice", "issues": ["tp_role_unrecognized"]})
            continue
        chtz, parent_evidence, issue = find_chtz(identifier)
        uncertain |= issue is not None
        if chtz:
            resolved_chtz.add(chtz)
        records.append({"mode": "separate_tp" if chtz else "unresolved", "chtz": chtz,
                        "developer_task": identifier, "related_tp": identifier,
                        "evidence": evidence + parent_evidence + members.get(chtz, []),
                        "rule": "source_type_slice_and_parent_chain", "issues": [issue] if issue else []})
    for identifier, evidence in sorted(members.items()):
        if objects[identifier].get("tp_role") != CHTZ or identifier in resolved_chtz:
            continue
        records.append({"mode": "unresolved" if uncertain else "same_tp", "chtz": identifier,
                        "developer_task": None if uncertain else identifier, "related_tp": identifier,
                        "evidence": evidence, "rule": "chtz_is_task_when_no_separate_task",
                        "issues": ["other_memberships_unresolved"] if uncertain else []})
    return records
