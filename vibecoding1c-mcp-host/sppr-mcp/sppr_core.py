"""Shared SPPR contracts. No network, process management or global state."""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote, urlsplit
from uuid import UUID
from uuid import uuid4
from xml.etree import ElementTree as ET
from zoneinfo import ZoneInfo


class SpprError(RuntimeError):
    """Messages are safe for callers: never put remote bodies or credentials here."""


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def now():
    return datetime.now(timezone.utc).isoformat()


def atomic_json(path, value):
    temp = path.with_name(path.name + "." + uuid4().hex + ".tmp")
    try:
        with temp.open("w", encoding="utf-8", newline="\n") as stream:
            stream.write(canonical(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def guid(value):
    try:
        return str(UUID(str(value)))
    except (ValueError, TypeError, AttributeError):
        raise SpprError("Invalid object UUID; use the typed identifier returned by search.") from None


def key(kind, value):
    if kind not in KINDS:
        raise SpprError("Unsupported object type; use a type returned by search.")
    return kind + ":" + guid(value)


def split_key(value):
    try:
        kind, identifier = value.split(":", 1)
        key(kind, identifier)
        return kind, guid(identifier)
    except (AttributeError, ValueError):
        raise SpprError("Expected Catalog_Name:UUID or Document_Name:UUID.") from None


@dataclass(frozen=True)
class Kind:
    owner: str | None = "Owner_Key"
    tables: tuple[str, ...] = ()


KINDS = {
    "Catalog_ТехническиеПроекты": Kind(tables=("ИдеиИОшибки", "Процессы", "Функции", "РазделыПроекта", "LCM_ФункциональныеРешения", "ДополнительныеРеквизиты")),
    "Catalog_Идеи": Kind(tables=("РазделыПроекта", "итлПроцессы", "итлШагиПроцессов", "LCM_ФункциональныеРешения", "ДополнительныеРеквизиты")),
    "Catalog_Процессы": Kind(tables=("ПредшествующиеПроцессы", "РазделыПроекта", "итлИдеи")),
    "Catalog_ШагиПроцесса": Kind(tables=("итлИдеи",)),
    "Catalog_РазделыПроекта": Kind(),
    "Catalog_ФункцииСистемы": Kind(),
    "Catalog_ЦелевыеЗадачи": Kind(tables=("РазделыПроекта",)),
    "Document_итлПротоколВстреч": Kind("Проект_Key", ("ФункциональныеТребования",)),
    "Catalog_LCM_Решения": Kind(None),
    "Catalog_LCM_Проблемы": Kind(None),
    "Catalog_LCM_ФункциональныеРешения": Kind(None, ("Проблемы",)),
}
SHARED = frozenset(k for k, v in KINDS.items() if v.owner is None)
STEP = "Catalog_ШагиПроцесса"
PROCESS = "Catalog_Процессы"
ZERO = str(UUID(int=0))
IDENTITY = {"Ref_Key", "DataVersion", "DeletionMark", "Owner_Key", "Проект_Key"}
TEXT_FIELDS = set("Description Code Number Date Описание ПодробноеОписание Заметки Комментарий КонцепцияПроекта ЦелиПроекта итлОписание Проблематика Результат КогдаСтартует ЧемЗавершается ТребованияКСистеме ПовесткаВстречи ОбсужденияИРешения МестоПроведения ПолныйКод НаименованиеВИнтерфейсе итлПричина".split())
BUSINESS_FIELDS = TEXT_FIELDS | set("Parent_Key IsFolder Статус Важность ДатаЗакрытия ДатаРегистрации ДатаНачала ДатаОкончания ДатаЗавершения ПлановаяДатаНачала ПлановаяДатаОкончания ДатаПроведения ТипФункции ТипШага итлТипПроцесса Очередность Ответственный_Key Исполнитель_Key итлИсполнитель_Key итлРазработчик_Key итлТестирующий_Key итлСтатусРаботы_Key СтатусПротокола_Key итлТип_Key итлТипИдеи_Key итлСпринтДляПроработкиАналитиком_Key итлСпринтДляРазработки_Key итлСсылкаНаМантис итлКодMantis итлСостояниеMantis РазделПроекта_Key ЦелеваяЗадача_Key ФункцияСистемы_Key ВложенныйПроцесс_Key итлВложенныйПроцесс_Key Решение_Key итлРодитель_Key итлВладелецПроцесса_Key".split())
BUSINESS_FIELDS.update("Зарегистрировал_Key Источник_Key Основание Основание_Type Тематика".split())
RICH_FIELDS = {"ХранилищеОписания", "ХранилищеЗаметок", "ХранилищеКонцепции", "ХранилищеЦелей", "ХранилищеОбсужденийИРешений", "ХранилищеФункциональногоТребования"}
ROW_FIELDS = set("Ref_Key LineNumber Идея_Key Идея Идея_Type Раздел_Key Процесс_Key ШагПроцесса_Key Гиперссылка_Key ФункциональноеРешение_Key Проблема_Key ОписаниеИзменений РеализацияИдеи итлРеализацияИдеиРазработчика итлРеализацияИдеиСтрока итлКомментарий итлКомментарийСтрока ФункциональноеТребование".split())
ROW_FIELDS.update("ТехническийИдентификатор_Key Свойство_Key Значение Значение_Type ТекстоваяСтрока".split())
LOOKUPS = {"Catalog_Пользователи", "Catalog_итлСтатусыРаботТехническихПроектов", "Catalog_итлТипыТП", "Catalog_итлТипИдеи", "Catalog_итлСпринты", "Catalog_итлСтатусыПротокола", "Catalog_Роли"}
LOOKUPS.update({"Catalog_итлСтатусыИдей", "Catalog_ИсточникиИдей", "Catalog_итлСтатусыРабот",
                "Catalog_ПрофилиПользователей", "Catalog_итлСтатусыРаботШагиПроцессов", "Catalog_итлКонтрагенты"})
LOOKUPS.update({"ChartOfCharacteristicTypes_ДополнительныеРеквизитыИСведения",
                "Catalog_ЗначенияСвойствОбъектов", "Catalog_ЗначенияСвойствОбъектовИерархия"})
POLYMORPHIC_FIELDS = {"Идея", "Основание", "Значение"}
FILTER_FIELDS = {
    "status": ("итлСтатусРаботы_Key", "СтатусПротокола_Key", "Статус"),
    "developer": ("итлРазработчик_Key",), "tester": ("итлТестирующий_Key",),
    "business_type": ("итлТип_Key", "итлТипИдеи_Key", "ТипФункции", "ТипШага", "итлТипПроцесса"),
    "sprint": ("итлСпринтДляПроработкиАналитиком_Key", "итлСпринтДляРазработки_Key"),
}


def reference_type(value):
    """Only an explicit entity type can make a polymorphic value a reference."""
    name = str(value or "").split(".")[-1]
    return name if re.fullmatch(r"(?:Catalog|Document|ChartOfCharacteristicTypes)_[\w]+", name) else None


@dataclass(frozen=True)
class Settings:
    state: Path
    policy: Path
    odata_url: str = "http://pskov.itland.local:8080/itland_work_SPPR/odata/standard.odata/"
    native_base: str = "e1c://server/pskov/itland_work_SPPR"
    web_base: str = "http://pskov.itland.local:8080/itland_work_SPPR/"
    api_base: str = "https://openrouter.ai/api/v1"
    model: str = "qwen/qwen3-embedding-8b"
    dimension: int = 4096
    query_instruction: str = "Instruct: Retrieve SPPR objects relevant to this query\nQuery: "
    cache_size: int = 256
    page_size: int = 100
    timeout: int = 30
    embedding_timeout: int = 120
    query_timeout: int = 25
    max_response_bytes: int = 16 * 1024 * 1024
    max_objects: int = 100000
    chunk_chars: int = 1800
    night_start: str = "01:00"
    night_end: str = "06:00"
    time_zone: str = "Europe/Moscow"
    generations_to_keep: int = 3
    embedding_workers: int = 4
    embedding_batch_size: int = 16
    embedding_run_seconds: int = 240
    embedding_interval_minutes: int = 5

    @classmethod
    def load(cls, path):
        try:
            data = json.loads(Path(path).read_text(encoding="utf-8-sig"))
            data["state"] = Path(data["state"])
            data["policy"] = Path(data["policy"])
            result = cls(**data)
            result.validate()
            return result
        except (OSError, ValueError, TypeError, KeyError):
            raise SpprError("Invalid SPPR config; check config.example.json and absolute state/policy paths.") from None

    def validate(self):
        if not self.state.is_absolute() or not self.policy.is_absolute():
            raise SpprError("State and policy paths must be absolute.")
        for url in (self.odata_url, self.web_base, self.api_base):
            p = urlsplit(url)
            if p.scheme not in ("http", "https") or not p.hostname or p.username or p.password or p.query or p.fragment:
                raise SpprError("Configure a credential-free base URL without query or fragment.")
        if not self.odata_url.endswith("/standard.odata/") or not self.native_base.startswith("e1c://server/"):
            raise SpprError("Check the standard.odata publication and native infobase base URL.")
        native = urlsplit(self.native_base)
        if native.username or native.password or native.query or native.fragment or len(native.path.strip('/').split('/')) != 2:
            raise SpprError("Native base must contain only the server and infobase names, without credentials.")
        if self.model != "qwen/qwen3-embedding-8b" or self.dimension < 1 or self.dimension > 4096:
            raise SpprError("Use the approved Qwen3 embedding profile and verified dimension.")
        if not 1 <= self.cache_size <= 10000 or not 1 <= self.page_size <= 1000 or not 256 <= self.chunk_chars <= 8000:
            raise SpprError("Cache, page or chunk limits are outside supported bounds.")
        if self.generations_to_keep < 2 or self.timeout < 1 or not 1 <= self.embedding_timeout <= 300 or not 1 <= self.query_timeout <= 60 or self.max_objects < 1:
            raise SpprError("Keep at least two generations and use positive runtime limits.")
        if not 1 <= self.embedding_workers <= 6 or not 1 <= self.embedding_batch_size <= 32 or not 30 <= self.embedding_run_seconds <= 600:
            raise SpprError("Embedding worker limits are outside supported bounds.")
        if not 1 <= self.embedding_interval_minutes <= 60:
            raise SpprError("Embedding schedule interval must be 1..60 minutes.")
        for value in (self.night_start, self.night_end):
            if not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", value):
                raise SpprError("Night window must use HH:MM.")
        if self.night_start == self.night_end:
            raise SpprError("Night window cannot cover all 24 hours.")
        ZoneInfo(self.time_zone)

    @property
    def source_id(self):
        return digest(self.odata_url.rstrip("/"))

    @property
    def profile(self):
        return digest({"provider": self.api_base, "model": self.model, "dimension": self.dimension,
                       "query_instruction": self.query_instruction, "extractor": 1,
                       "chunk_chars": self.chunk_chars, "normalization": "float32-unit-v1"})

    def in_window(self, at=None):
        local = (at or datetime.now(timezone.utc)).astimezone(ZoneInfo(self.time_zone)).strftime("%H:%M")
        if self.night_start < self.night_end:
            return self.night_start <= local < self.night_end
        return local >= self.night_start or local < self.night_end


@dataclass(frozen=True)
class Policy:
    projects: frozenset[str]
    token: str

    @classmethod
    def load(cls, path):
        try:
            data = json.loads(Path(path).read_text(encoding="utf-8-sig"))
            projects = frozenset(guid(x) for x in data["projects"])
            if set(data) != {"projects"} or not isinstance(data["projects"], list):
                raise ValueError()
            return cls(projects, digest(sorted(projects)))
        except (OSError, ValueError, KeyError, TypeError):
            raise SpprError("Policy unavailable or invalid; restore the allowlist file before retrying.") from None

    def permits(self, roots):
        return bool(self.projects.intersection(roots))

    def unchanged(self, path):
        if Policy.load(path).token != self.token:
            raise SpprError("Project policy changed; restart the operation under the current allowlist.")


def safe_xml(data, limit=16 * 1024 * 1024):
    if len(data) > limit:
        raise SpprError("XML exceeds the configured extraction limit.")
    # XML may be UTF-16. Reject declarations after removing NULs as well as in UTF-8.
    probe = data.replace(b"\x00", b"").upper()
    if b"<!DOCTYPE" in probe or b"<!ENTITY" in probe:
        raise SpprError("External entities and DTDs are not supported.")
    try:
        return ET.fromstring(data)
    except ET.ParseError:
        raise SpprError("Unsupported or malformed XML; extraction coverage is incomplete.") from None


def rich_text(encoded, content_type):
    if not encoded:
        return ""
    if content_type != "application/xml+xdto":
        raise SpprError("Unsupported rich-text content type.")
    try:
        if isinstance(encoded, str):
            # 1C wraps Base64 lines; retain strict validation of every other character.
            encoded = encoded.translate(str.maketrans("", "", " \t\r\n"))
        data = base64.b64decode(encoded, validate=True)
    except (ValueError, TypeError):
        raise SpprError("Invalid Base64 description.") from None
    root = safe_xml(data)
    if root.tag.rsplit("}", 1)[-1] != "FormattedDocument":
        raise SpprError("Unsupported XDTO description root.")
    paragraphs = []
    for element in root.iter():
        if element.tag.rsplit("}", 1)[-1] == "p":
            texts = [e.text or "" for e in element.iter() if e.tag.rsplit("}", 1)[-1] == "text"]
            paragraphs.append("".join(texts))
    if not paragraphs:
        paragraphs = [e.text or "" for e in root.iter() if e.tag.rsplit("}", 1)[-1] == "text"]
    links = []
    for element in root.iter():
        values = [v for n, v in element.attrib.items() if n.rsplit('}', 1)[-1].lower() in ('href', 'url')]
        if element.tag.rsplit('}', 1)[-1].lower() in ('href', 'url'):
            values.append(element.text or '')
        links.extend(v for v in values if v.startswith(('http://', 'https://', 'e1cib/', 'e1c://')))
    if not paragraphs and any(e.text and e.text.strip() for e in root.iter() if e.tag.rsplit('}', 1)[-1] not in ('id', 'FormattedDocument')):
        raise SpprError("FormattedDocument has unsupported text nodes; extraction coverage is incomplete.")
    paragraphs.extend(dict.fromkeys(links))
    return "\n".join(paragraphs).strip()


def navigation(settings, kind, identifier):
    key(kind, identifier)
    groups = guid(identifier).split("-")
    ref = "".join(groups[i] for i in (3, 4, 2, 1, 0))
    family, name = kind.split("_", 1)
    family = {"Catalog": "Справочник", "Document": "Документ"}[family]
    internal = f"e1cib/data/{family}.{name}?ref={ref}"
    encoded = quote(internal, safe="/?.=&")
    return {"internal": internal, "native": settings.native_base + "#" + encoded,
            "web": settings.web_base.rstrip("/") + "/#" + encoded}


def fields_from(raw, available):
    fields = {}
    for name in sorted(available):
        if name.endswith("_Base64Data") or (name.endswith("_Type") and name[:-5] not in POLYMORPHIC_FIELDS) or name in IDENTITY:
            continue
        value = raw.get(name)
        fields[name] = {"state": "value" if value not in (None, "") else "empty", "value": value}
        if name in POLYMORPHIC_FIELDS:
            fields[name]["value_type"] = raw.get(name + "_Type")
            fields[name]["reference_type"] = reference_type(raw.get(name + "_Type"))
    for name in sorted(RICH_FIELDS):
        if name + "_Base64Data" not in available:
            continue
        try:
            value = rich_text(raw.get(name + "_Base64Data"), raw.get(name + "_Type"))
            fields[name] = {"state": "value" if value else "empty", "value": value}
        except SpprError as exc:
            fields[name] = {"state": "unreadable", "value": None, "reason": str(exc)}
    for aliases in FILTER_FIELDS.values():
        for name in aliases:
            if name not in available:
                fields.setdefault(name, {"state": "not_applicable", "value": None})
    return fields


def fragments(fields, size):
    for name, record in fields.items():
        value = record.get("value")
        texts = []
        if record.get("label"):
            texts.append((name + "/label", record["label"]))
        if record.get("state") == "value" and not name.endswith(("_Key", "_Type")) and not record.get("reference_type"):
            if isinstance(value, str):
                texts.append((name, value))
            elif isinstance(value, (bool, int, float)) and record.get("value_type"):
                texts.append((name, canonical(value)))
        for field_name, text in texts:
            text = text.strip()
            # Exact non-overlapping offsets let full reading reconstruct every character.
            for offset in range(0, len(text), size):
                yield {"field": field_name, "offset": offset, "text": text[offset:offset + size]}
