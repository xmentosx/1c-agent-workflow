from __future__ import annotations

import base64
import copy
import json
import tempfile
import unittest
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch
from uuid import UUID

import numpy as np

from sppr_core import (BUSINESS_FIELDS, IDENTITY, KINDS, LOOKUPS, Policy, Settings, SpprError,
                       fields_from, guid, key, navigation, rich_text)
from sppr_embeddings import QueryCache, vector
from sppr_odata import Collection, Schema, collect
from sppr_service import Service
from sppr_store import Store, atomic_json, writer_lock

TP = "Catalog_ТехническиеПроекты"
IDEA = "Catalog_Идеи"
PROCESS = "Catalog_Процессы"
STEP = "Catalog_ШагиПроцесса"
SOLUTION = "Catalog_LCM_Решения"
PROBLEM = "Catalog_LCM_Проблемы"
FUNCTION = "Catalog_ФункцииСистемы"
A, B = str(UUID(int=1000)), str(UUID(int=2000))


def uuid(number):
    return str(UUID(int=number))


def fixture_schema():
    entities, associations = [], []
    def entity(name, fields, refs):
        props = ''.join(f'<Property Name="{n}" Type="{t}"/>' for n, t in fields.items())
        nav = ''
        for column, target in refs.items():
            relation = name + "_" + column
            nav += f'<NavigationProperty Name="{column[:-4]}" Relationship="StandardODATA.{relation}" ToRole="End"/>'
            associations.append(f'<Association Name="{relation}"><End Role="End" Type="StandardODATA.{target}"/></Association>')
        entities.append(f'<EntityType Name="{name}">{props}{nav}</EntityType>')
    for kind, contract in KINDS.items():
        fields = {"Ref_Key": "Edm.Guid", "DataVersion": "Edm.String", "DeletionMark": "Edm.Boolean",
                  "Description": "Edm.String", "Описание": "Edm.String", "Code": "Edm.String",
                  "IsFolder": "Edm.Boolean", "Статус": "Edm.String", "ПарольПользователяХранилищаДляЗагрузкиМетаданных": "Edm.String",
                  "ХранилищеОписания_Base64Data": "Edm.Binary", "ХранилищеОписания_Type": "Edm.String"}
        if contract.owner:
            fields[contract.owner] = "Edm.Guid"
        refs = {}
        if kind == TP:
            fields.update({"итлКодMantis": "Edm.String", "итлРазработчик_Key": "Edm.Guid", "Решение_Key": "Edm.Guid"})
            refs.update({"итлРазработчик_Key": "Catalog_Пользователи", "Решение_Key": SOLUTION})
            for name, target in (("итлТестирующий_Key", "Catalog_Пользователи"),
                                 ("итлТип_Key", "Catalog_итлТипыТП"),
                                 ("итлСпринтДляПроработкиАналитиком_Key", "Catalog_итлСпринты"),
                                 ("итлСпринтДляРазработки_Key", "Catalog_итлСпринты")):
                fields[name], refs[name] = "Edm.Guid", target
        if kind == IDEA:
            fields["итлСтатусРаботы_Key"] = "Edm.Guid"
            refs["итлСтатусРаботы_Key"] = "Catalog_итлСтатусыИдей"
        if kind in (SOLUTION, PROBLEM):
            fields["Parent_Key"] = "Edm.Guid"
            refs["Parent_Key"] = SOLUTION
        entity(kind, fields, refs)
        for table in contract.tables:
            row_fields = {"Ref_Key": "Edm.Guid", "LineNumber": "Edm.Int64"}
            row_refs = {}
            if table == "ИдеиИОшибки":
                row_fields.update({"Идея": "Edm.String", "Идея_Type": "Edm.String", "РеализацияИдеи": "Edm.String", "итлКомментарий": "Edm.String"})
            else:
                column, target = {"Процессы": ("Гиперссылка_Key", PROCESS), "Функции": ("Гиперссылка_Key", FUNCTION),
                                  "итлИдеи": ("Идея_Key", IDEA), "ПредшествующиеПроцессы": ("Процесс_Key", PROCESS),
                                  "итлПроцессы": ("Процесс_Key", PROCESS), "итлШагиПроцессов": ("ШагПроцесса_Key", STEP),
                                  "ФункциональныеТребования": ("Идея_Key", IDEA), "Проблемы": ("Проблема_Key", PROBLEM),
                                  "LCM_ФункциональныеРешения": ("ФункциональноеРешение_Key", "Catalog_LCM_ФункциональныеРешения")}.get(table, ("Раздел_Key", "Catalog_РазделыПроекта"))
                row_fields[column] = "Edm.Guid"
                row_refs[column] = target
            entity(kind + "_" + table, row_fields, row_refs)
    for kind in sorted(LOOKUPS):
        entity(kind, {"Ref_Key": "Edm.Guid", "Description": "Edm.String", "DataVersion": "Edm.String", "DeletionMark": "Edm.Boolean"}, {})
    return ('<Schema>' + ''.join(entities + associations) + '</Schema>').encode()


class FakeSource:
    def __init__(self):
        self.schema = Schema(fixture_schema())
        self.data, self.rows, self.reads = {}, {}, []
        self.fail_inventory = False
        self.inventory_calls = 0

    def add(self, kind, number, project=A, **fields):
        raw = {"Ref_Key": uuid(number), "DataVersion": "v1", "DeletionMark": False,
               "Description": f"Карточка {number}", "Code": str(number), "IsFolder": False,
               "Описание": "Описание проблемы планирования", "Статус": "Закрыта",
               "ПарольПользователяХранилищаДляЗагрузкиМетаданных": "DO-NOT-READ-SECRET", **fields}
        if KINDS[kind].owner:
            raw[KINDS[kind].owner] = project
        self.data[key(kind, uuid(number))] = raw
        return raw

    def inventory(self, kind, owner):
        self.inventory_calls += 1
        if self.fail_inventory:
            raise SpprError("fixture failed page")
        return [self.header(kind, r["Ref_Key"]) for k, r in self.data.items()
                if k.startswith(kind + ":") and r.get(KINDS[kind].owner) == owner and not r["DeletionMark"]]

    def header(self, kind, identifier):
        raw = self.data[key(kind, identifier)]
        names = {"Ref_Key", "DataVersion", "DeletionMark", KINDS[kind].owner}
        return {n: raw[n] for n in names if n in raw}

    def read(self, kind, identifier, fields):
        self.reads.append((kind, identifier, fields))
        return {n: v for n, v in self.data[kind + ":" + identifier].items() if n in fields}

    def read_scoped(self, kind, identifier, fields, header):
        if self.header(kind, identifier) != header:
            raise SpprError("changed")
        return self.read(kind, identifier, fields)

    def table(self, kind, identifier, name):
        return copy.deepcopy(self.rows.get((kind, identifier, name), []))

    def idea_row(self, tp, idea, text, row=1, kind=IDEA):
        self.rows.setdefault((TP, uuid(tp), "ИдеиИОшибки"), []).append(
            {"Ref_Key": uuid(tp), "LineNumber": row, "Идея": uuid(idea), "Идея_Type": "StandardODATA." + kind,
             "РеализацияИдеи": text, "итлКомментарий": "Комментарий строки"})


class FakeEmbeddings:
    def __init__(self, dimension=4):
        self.calls, self.dimension, self.fail, self.hook = [], dimension, False, None
        self.usage = {}

    def embed(self, texts):
        self.calls.append(texts[:])
        if self.hook:
            self.hook()
        if self.fail:
            raise SpprError("fixture provider unavailable")
        return [vector([len(text) % 7 + 1, text.count("а") + 1, text.count("п") + 1, 1], self.dimension) for text in texts]


class SpprTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="СППР с пробелом ")
        root = Path(self.temp.name)
        self.settings = Settings(root / "state", root / "policy.json", dimension=4, cache_size=2)
        self.set_policy([A])
        self.source = FakeSource()
        self.source.add(TP, 1, итлКодMantis="54321", Решение_Key=uuid(6))
        self.source.add(TP, 2)
        self.source.add(IDEA, 3)
        self.source.add(PROCESS, 4)
        self.source.add(STEP, 5, project=uuid(4))
        self.source.add(SOLUTION, 6, project=None, Parent_Key=uuid(7))
        self.source.add(SOLUTION, 7, project=None, Parent_Key=uuid(6))
        self.source.add(TP, 90, project=B, Description="FOREIGN-TEXT-TRAP")
        self.source.idea_row(1, 3, "Реализация в первом ТП")
        self.source.idea_row(2, 3, "Другая реализация во втором ТП")
        self.source.idea_row(1, 90, "Ссылка на исключённый ТП", row=2, kind=TP)
        self.provider = FakeEmbeddings()
        self.store = Store(self.settings)

    def tearDown(self):
        self.temp.cleanup()

    def set_policy(self, projects):
        self.settings.policy.write_text(json.dumps({"projects": projects}), encoding="utf-8")
        self.policy = Policy.load(self.settings.policy)

    def collect(self, previous=None):
        return collect(self.source, self.settings, self.policy, previous)

    def publish(self):
        previous, vectors = self.store.previous()
        return self.store.publish(self.collect(previous), self.policy, self.provider, vectors)

    def test_scope_shared_cycles_steps_and_secret_projections(self):
        collected = self.collect()
        self.assertIn(key(STEP, uuid(5)), collected.objects)
        self.assertNotIn(key(TP, uuid(90)), collected.objects)
        self.assertEqual(collected.objects[key(SOLUTION, uuid(6))]["roots"], [A])
        self.assertTrue(collected.objects[key(SOLUTION, uuid(7))]["provenance"][A])
        self.assertFalse(any(identifier == uuid(90) for _, identifier, _ in self.source.reads))
        self.assertNotIn("DO-NOT-READ-SECRET", json.dumps(collected.objects))
        self.assertFalse(any("ПарольПользователяХранилищаДляЗагрузкиМетаданных" in fields for _, _, fields in self.source.reads))

    def test_relation_realizations_remain_distinct_and_readable(self):
        self.publish()
        service = Service(self.settings, self.provider)
        result = service.relations(key(IDEA, uuid(3)), limit=1)
        all_rows = result["relations"][:]
        while result["cursor"]:
            result = service.relations(key(IDEA, uuid(3)), limit=1, cursor=result["cursor"])
            all_rows.extend(result["relations"])
        self.assertEqual(len(all_rows), 2)
        texts = []
        for row in all_rows:
            read = service.read(**row["read_text"], limit=20)
            texts.extend(f["value"] for f in read["fields"] if f["field"] == "РеализацияИдеи")
        self.assertCountEqual(texts, ["Реализация в первом ТП", "Другая реализация во втором ТП"])

    def test_table_updates_do_not_depend_on_parent_version(self):
        self.publish()
        old, vectors = self.store.previous()
        self.source.rows[(TP, uuid(1), "ИдеиИОшибки")][0]["РеализацияИдеи"] = "Новая реализация без смены версии"
        result = self.collect(old)
        self.assertIn("Новая реализация без смены версии", json.dumps(result.edges, ensure_ascii=False))
        before = len(self.provider.calls)
        self.store.publish(result, self.policy, self.provider, vectors)
        new_calls = self.provider.calls[before:]
        self.assertEqual(sum(map(len, new_calls)), 1)

    def test_textual_row_without_reference_remains_searchable(self):
        self.source.rows[(TP, uuid(1), "ИдеиИОшибки")].append({
            "Ref_Key": uuid(1), "LineNumber": 3, "Идея": uuid(0),
            "Идея_Type": "StandardODATA." + IDEA, "РеализацияИдеи": "Уникальное требование без ссылки"})
        self.publish()
        service = Service(self.settings, self.provider)
        hit = service.search("Уникальное требование без ссылки")["hits"][0]
        self.assertEqual(hit["id"], key(TP, uuid(1)))
        fields, cursor = [], None
        while True:
            page = service.read(hit["id"], cursor=cursor, limit=20)
            fields.extend(page["fields"])
            cursor = page["cursor"]
            if not cursor:
                break
        self.assertIn("Уникальное требование без ссылки", [f.get("value") for f in fields])
        self.assertFalse(any(e["target"]["id"].endswith(uuid(0)) for e in service.relations(hit["id"])["relations"]))

    def test_deleted_and_moved_objects_removed_after_success(self):
        self.publish()
        self.source.data[key(IDEA, uuid(3))]["DeletionMark"] = True
        self.source.data[key(TP, uuid(2))]["Owner_Key"] = B
        self.publish()
        old, _ = self.store.previous()
        self.assertNotIn(key(IDEA, uuid(3)), old)
        self.assertNotIn(key(TP, uuid(2)), old)

    def test_failed_scan_retains_previous_manifest(self):
        original = self.publish()
        self.source.fail_inventory = True
        with self.assertRaises(SpprError):
            self.publish()
        self.assertEqual(self.store.manifest()["generation"], original["generation"])

    def test_unstable_inventory_rejects_new_generation(self):
        original = self.source.inventory
        count = 0
        def changing(kind, owner):
            nonlocal count
            count += 1
            if count > 8 and kind == TP:
                self.source.data[key(TP, uuid(1))]["DataVersion"] = "changed"
            return original(kind, owner)
        self.source.inventory = changing
        with self.assertRaisesRegex(SpprError, "inventory changed"):
            self.collect()

    def test_allowlist_revocation_applies_before_sync_and_rollback(self):
        generation = self.publish()
        service = Service(self.settings, self.provider)
        page = service.read(key(TP, uuid(1)), limit=1)
        self.set_policy([])
        self.assertEqual(service.search("планирование")["hits"], [])
        with self.assertRaises(SpprError):
            service.read(key(TP, uuid(1)), limit=1, cursor=page["cursor"])
        self.store.rollback(generation["generation"])
        self.assertEqual(service.search("планирование")["hits"], [])

    def test_revocation_during_embedding_does_not_publish(self):
        self.publish()
        generation = self.store.manifest()["generation"]
        self.provider.hook = lambda: self.set_policy([])
        with self.assertRaisesRegex(SpprError, "policy changed"):
            self.store.publish(self.collect(), self.policy, self.provider)
        self.assertEqual(self.store.manifest()["generation"], generation)

    def test_query_lru_and_new_generation_results(self):
        self.publish()
        service = Service(self.settings, self.provider)
        first = service.search("54321")
        self.assertEqual(first["hits"][0]["id"], key(TP, uuid(1)))
        calls = len(self.provider.calls)
        self.assertTrue(service.search("54321")["query_vector_cached"])
        self.assertEqual(calls, len(self.provider.calls))
        self.source.data[key(TP, uuid(1))].update(Description="Новый заголовок", DataVersion="v2")
        self.publish()
        result = service.search("54321")
        self.assertTrue(result["query_vector_cached"])
        self.assertEqual(result["hits"][0]["title"], "Новый заголовок")
        service.search("второй")
        service.search("третий")
        self.assertEqual(len(service.queries.values), 2)
        self.assertFalse(service.search("54321")["query_vector_cached"])
        self.assertFalse(Service(self.settings, self.provider).search("54321")["query_vector_cached"])

    def test_outage_cached_uncached_and_changed_text(self):
        self.publish()
        service = Service(self.settings, self.provider)
        service.search("54321")
        self.provider.fail = True
        self.assertEqual(service.search("54321")["search_mode"], "hybrid")
        failed = service.search("проблемы")
        self.assertEqual(failed["search_mode"], "lexical_exact")
        self.assertTrue(failed["degradation"])
        self.source.data[key(TP, uuid(1))].update(Описание="НЕБЫВАЛЫЙ новый текст", DataVersion="v3")
        result = self.publish()
        self.assertFalse(result["semantic_complete"])
        with self.store.reader() as (db, _):
            self.assertIsNone(db.execute("SELECT vector FROM fragments WHERE text=?", ("НЕБЫВАЛЫЙ новый текст",)).fetchone()[0])

    def test_exact_filters_and_complete_long_field(self):
        text = "абзац с кириллицей " * 900
        self.source.data[key(TP, uuid(1))]["Описание"] = text
        self.publish()
        service = Service(self.settings, self.provider)
        result = service.search("54321", {"status": "Закрыта", "type": TP})
        self.assertEqual(result["hits"][0]["id"], key(TP, uuid(1)))
        self.assertEqual(service.search("54321", {"status": "Открыта"})["hits"], [])
        field_parts, cursor = [], None
        while True:
            page = service.read(key(TP, uuid(1)), cursor=cursor, limit=3)
            field_parts += [item["value"] for item in page["fields"] if item["field"] == "Описание"]
            cursor = page["cursor"]
            if not cursor:
                break
        self.assertEqual("".join(field_parts), text)

    def test_cursor_does_not_mix_generations(self):
        self.publish()
        service = Service(self.settings, self.provider)
        first = service.read(key(TP, uuid(1)), limit=1)
        self.publish()
        with self.assertRaisesRegex(SpprError, "Continuation"):
            service.read(key(TP, uuid(1)), limit=1, cursor=first["cursor"])

    def test_single_writer_and_crash_before_pointer(self):
        original = self.publish()
        with writer_lock(self.settings.state):
            with self.assertRaisesRegex(SpprError, "already running"):
                with writer_lock(self.settings.state):
                    self.fail("second writer admitted")
        with patch("sppr_store.atomic_json", side_effect=OSError("disk failed")):
            with self.assertRaises(OSError):
                self.publish()
        self.assertEqual(self.store.manifest()["generation"], original["generation"])
        self.assertEqual(list(self.settings.state.glob("*.staging")), [])

    def test_profile_and_dimension_mismatch(self):
        self.publish()
        changed = replace(self.settings, query_instruction="different")
        self.assertEqual(Store(changed).previous()[1], {})
        result = Service(changed, self.provider).search("54321")
        self.assertEqual(result["search_mode"], "lexical_exact")
        for invalid in ([1, 2], [0, 0, 0, 0], [float("nan"), 1, 2, 3]):
            with self.assertRaises(SpprError):
                vector(invalid, 4)

    def test_rich_text_formats_and_external_entities(self):
        xml = '<FormattedDocument><id>INTERNAL-ID</id><content><p><text>Первый</text></p><p><text>Второй</text></p></content></FormattedDocument>'
        encoded = base64.b64encode(xml.encode()).decode()
        self.assertEqual(rich_text(encoded, "application/xml+xdto"), "Первый\nВторой")
        for xml in ('<!DOCTYPE x [<!ENTITY y SYSTEM "http://trap.test">]><FormattedDocument/>', '<Unknown/>', '<broken',
                    '<FormattedDocument><unknown>unreadable content</unknown></FormattedDocument>'):
            with self.assertRaises(SpprError):
                rich_text(base64.b64encode(xml.encode()).decode(), "application/xml+xdto")
        with self.assertRaises(SpprError):
            rich_text(encoded, "application/octet-stream")
        linked = base64.b64encode(b'<FormattedDocument><p><text>link</text><url>https://example.test/card</url></p></FormattedDocument>').decode()
        self.assertEqual(rich_text(linked, "application/xml+xdto"), "link\nhttps://example.test/card")

    def test_business_fields_filters_and_field_states(self):
        tp = self.source.data[key(TP, uuid(1))]
        rows = [("итлРазработчик_Key", "Catalog_Пользователи", "Разработчик", "developer"),
                ("итлТестирующий_Key", "Catalog_Пользователи", "Тестирующий", "tester"),
                ("итлТип_Key", "Catalog_итлТипыТП", "Доработка", "business_type"),
                ("итлСпринтДляПроработкиАналитиком_Key", "Catalog_итлСпринты", "Аналитика", "sprint"),
                ("итлСпринтДляРазработки_Key", "Catalog_итлСпринты", "Разработка", "sprint")]
        for number, (field, kind, label, _) in enumerate(rows, 100):
            tp[field] = uuid(number)
            self.source.data[kind + ":" + uuid(number)] = {
                "Ref_Key": uuid(number), "Description": label, "DataVersion": "v1", "DeletionMark": False}
        tp["ХранилищеОписания_Base64Data"] = base64.b64encode(b"<Unknown/>").decode()
        tp["ХранилищеОписания_Type"] = "application/xml+xdto"
        self.publish()
        service = Service(self.settings, self.provider)
        for _, _, label, name in rows:
            result = service.search("54321", {name: label, "type": TP})
            self.assertEqual(result["hits"][0]["id"], key(TP, uuid(1)))
        stored = self.store.previous()[0]
        self.assertEqual(stored[key(TP, uuid(1))]["fields"]["ХранилищеОписания"]["state"], "unreadable")
        self.assertEqual(stored[key(TP, uuid(2))]["fields"]["итлТестирующий_Key"]["state"], "empty")
        self.assertEqual(stored[key(IDEA, uuid(3))]["fields"]["итлТестирующий_Key"]["state"], "not_applicable")

    def test_unknown_type_and_secret_fields_do_not_expand_scope(self):
        self.source.idea_row(2, 91, "unsupported target", row=2, kind="Catalog_ФункцииМеханизмов")
        result = self.collect()
        self.assertGreater(result.coverage["unsupported_references"], 0)
        self.assertFalse(any(identifier == uuid(91) for _, identifier, _ in self.source.reads))

    def test_navigation_uuid_layout_and_rename_stability(self):
        # Native Get Link sample supplied by the SPPR user, 2026-09-28.
        identifier = "5b94bf37-7728-11ef-8122-000c295e34e3"
        links = navigation(self.settings, TP, identifier)
        self.assertEqual(links["internal"], "e1cib/data/Справочник.ТехническиеПроекты?ref=8122000c295e34e311ef77285b94bf37")
        self.assertIn("pskov/itland_work_SPPR", links["native"])
        self.assertIn("itland_work_SPPR/", links["web"])
        self.assertNotIn("password", json.dumps(links))

    def test_night_window_and_fail_closed_policy(self):
        self.assertTrue(self.settings.in_window(datetime(2026, 1, 1, 0, 0, tzinfo=timezone.utc)))
        self.assertFalse(self.settings.in_window(datetime(2026, 1, 1, 9, 0, tzinfo=timezone.utc)))
        self.settings.policy.write_text('broken', encoding="utf-8")
        with self.assertRaisesRegex(SpprError, "Policy unavailable"):
            Policy.load(self.settings.policy)


    def test_two_project_roots_and_address_only_labels(self):
        self.source.data[key(TP, uuid(90))]["Решение_Key"] = uuid(6)
        self.source.data[key(IDEA, uuid(3))]["итлСтатусРаботы_Key"] = uuid(80)
        self.source.data["Catalog_итлСтатусыИдей:" + uuid(80)] = {
            "Ref_Key": uuid(80), "Description": "В работе", "DeletionMark": False,
            "DataVersion": "v1", "Secret": "LOOKUP-SECRET-TRAP"}
        self.set_policy([A, B])
        self.publish()
        service = Service(self.settings, self.provider)
        result = service.search("Карточка 3", {"type": IDEA, "status": "В работе"})
        self.assertEqual(result["hits"][0]["id"], key(IDEA, uuid(3)))
        lookups = [read for read in self.source.reads if read[0] == "Catalog_итлСтатусыИдей"]
        self.assertEqual(len(lookups), 1)
        self.assertNotIn("Secret", lookups[0][2])
        self.assertEqual(set(service.read(key(SOLUTION, uuid(6)))["object"]["roots"]), {A, B})
        self.set_policy([B])
        self.assertEqual(service.read(key(SOLUTION, uuid(6)))["object"]["roots"], [B])
        self.set_policy([])
        with self.assertRaises(SpprError):
            service.read(key(SOLUTION, uuid(6)))

    def test_runtime_admission_and_embedding_only_recovery(self):
        from collector import run
        original = self.publish()
        credentials = {"username": "fixture", "password": "fixture", "api_key": ""}
        with patch("collector.OData") as odata, patch.object(Settings, "in_window", return_value=False):
            with self.assertRaisesRegex(SpprError, "Outside the night"):
                run(self.settings, credentials, session_check=lambda: None)
            odata.assert_not_called()
        def signed_out():
            raise SpprError("User session is closing")
        with patch("collector.OData") as odata:
            with self.assertRaisesRegex(SpprError, "session is closing"):
                run(self.settings, credentials, outside_window=True, session_check=signed_out)
            odata.assert_not_called()
        self.assertEqual(self.store.manifest()["generation"], original["generation"])
        self.provider.fail = True
        self.source.data[key(TP, uuid(1))].update(Описание="Новый текст без вектора", DataVersion="v2")
        self.assertFalse(self.publish()["semantic_complete"])
        self.provider.fail = False
        with patch("collector.OData") as odata, patch("collector.Embeddings", return_value=self.provider):
            result = run(self.settings, credentials, operation="embed-pending", session_check=lambda: None)
            odata.assert_not_called()
        self.assertTrue(result["semantic_complete"])

    def test_publication_abort_on_session_loss_and_cleanup_failure(self):
        original = self.publish()
        def stopped():
            raise SpprError("User session is closing")
        with self.assertRaisesRegex(SpprError, "session is closing"):
            self.store.publish(self.collect(), self.policy, self.provider, before=stopped)
        self.assertEqual(self.store.manifest()["generation"], original["generation"])
        with patch.object(Path, "glob", side_effect=OSError("cleanup denied")):
            result = self.publish()
        self.assertEqual(self.store.manifest()["generation"], result["generation"])


if __name__ == "__main__":
    unittest.main()
