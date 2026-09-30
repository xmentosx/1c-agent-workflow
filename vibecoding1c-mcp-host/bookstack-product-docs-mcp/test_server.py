import json
import os
import sys
import tempfile
import types
import re
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import server


class FakeFastMCP:
    def __init__(self, name, **kwargs):
        self.name = name
        self.options = kwargs
        self.registered_tools = []

    def tool(self, function):
        self.registered_tools.append(function.__name__)
        return function


class FakeToolResult:
    def __init__(self, content=None, structured_content=None):
        self.content = content
        self.structured_content = structured_content


def fake_fastmcp_modules():
    fastmcp = types.ModuleType("fastmcp")
    fastmcp.__path__ = []
    fastmcp.FastMCP = FakeFastMCP
    tools = types.ModuleType("fastmcp.tools")
    tools.__path__ = []
    tool = types.ModuleType("fastmcp.tools.tool")
    tool.ToolResult = FakeToolResult
    return {"fastmcp": fastmcp, "fastmcp.tools": tools, "fastmcp.tools.tool": tool}


def make_settings(cache_path, embedding_model=""):
    return server.Settings(
        base_url="http://bookstack.local",
        token_id="token-id",
        token_secret="token-secret",
        cache_path=str(cache_path),
        timeout_seconds=5,
        host="127.0.0.1",
        port=8000,
        reindex_interval_hours=0,
        index_on_startup=False,
        max_index_pages=0,
        semantic_min_score=server.DEFAULT_SEMANTIC_MIN_SCORE,
        reset_database=False,
        embedding_api_base="",
        embedding_api_key="",
        embedding_model=embedding_model,
        embedding_cache_dir=str(cache_path.parent / "models"),
    )


def page(page_id, body):
    return {
        "id": page_id,
        "name": f"Architecture {page_id}",
        "url": f"http://bookstack.local/books/product/page/{page_id}",
        "book_id": 10,
        "chapter_id": 20,
        "book": {"name": "Product"},
        "chapter": {"name": "Architecture"},
        "tags": [{"name": "architecture"}],
        "updated_at": "2026-07-19T00:00:00Z",
        "markdown": body,
        "html": "",
    }


class ProductDocsTransportTests(unittest.TestCase):
    def test_create_mcp_enables_stateless_http(self):
        with tempfile.TemporaryDirectory() as temp_root:
            environment = {
                "BOOKSTACK_BASE_URL": "http://bookstack.local",
                "BOOKSTACK_TOKEN_ID": "token-id",
                "BOOKSTACK_TOKEN_SECRET": "token-secret",
                "BOOKSTACK_CACHE_PATH": str(Path(temp_root) / "cache.sqlite"),
                "BOOKSTACK_REINDEX_INTERVAL_HOURS": "0",
                "BOOKSTACK_INDEX_ON_STARTUP": "false",
            }
            with mock.patch.dict(os.environ, environment), mock.patch.dict(sys.modules, fake_fastmcp_modules()):
                mcp, _ = server.create_mcp()

        self.assertEqual(mcp.name, "bookstack-product-docs")
        self.assertIs(mcp.options.get("stateless_http"), True)
        self.assertEqual(
            mcp.registered_tools,
            ["search_docs", "read_page", "list_structure", "reindex_docs", "index_status"],
        )


class FakeClient:
    def __init__(self, pages):
        self.pages = {item["id"]: item for item in pages}
        self.search_calls = []

    def read_page(self, page_id):
        return self.pages[page_id]

    def export_page(self, page_id, fmt):
        return self.pages[page_id]["markdown"]

    def search(self, query, limit):
        self.search_calls.append((query, limit))
        return []

    def list_pages(self, max_items=0):
        pages = list(self.pages.values())
        return pages[:max_items] if max_items else pages

    def structure(self, scope, limit):
        values = []
        for index in range(limit):
            values.append(
                {
                    "id": index + 1,
                    "name": f"Item {index + 1}",
                    "url": f"http://bookstack.local/{scope}/{index + 1}",
                    "book_id": 10,
                    "description": "x" * 5000,
                    "books": [{"id": nested} for nested in range(100)],
                }
            )
        key = "pages" if scope == "all" else scope
        return {key: [server.compact_structure_item(item, key) for item in values]}


class FakeEmbeddings:
    def __init__(self, profile="fake-model::retrieval-v2"):
        self.model = "fake-model"
        self.profile = profile
        self.cache_dir = "/fake/model-cache"
        self.query_inputs = []
        self.passage_inputs = []

    def enabled(self):
        return True

    def mode(self):
        return "fake"

    def storage_model(self):
        return self.profile

    def embed_query(self, text):
        self.query_inputs.append(text)
        return [1.0, 0.0]

    def embed_passage(self, text):
        self.passage_inputs.append(text)
        page_id = int(text.split("\n", 1)[0].rsplit(" ", 1)[-1])
        return [1.0, page_id / 100.0]

    def split_page(self, title, text):
        return server.fragments(text, title, WordTokenizer(), 64, 4)

    def embed_passages(self, texts):
        return [self.embed_passage(text) for text in texts]


class WordTokenizer:
    def __call__(self, text, **kwargs):
        offsets = [(match.start(), match.end()) for match in re.finditer(r"\S+", text)]
        return {"input_ids": list(range(len(offsets))), "offset_mapping": offsets}

    def encode(self, text, **kwargs):
        return self(text)["input_ids"]


class LowConfidenceEmbeddings(FakeEmbeddings):
    def embed_passage(self, text):
        self.passage_inputs.append(text)
        return [0.8, 0.6]


class RankingEmbeddings(FakeEmbeddings):
    def embed_passage(self, text):
        self.passage_inputs.append(text)
        page_id = int(text.split("\n", 1)[0].rsplit(" ", 1)[-1])
        return [0.8, 0.6] if page_id == 1 else [1.0, 0.0]


class BookStackClientStructureTests(unittest.TestCase):
    def test_page_inventory_requires_complete_consistent_unique_batches(self):
        client = object.__new__(server.BookStackClient)
        for responses in (
            [{"data": [{"id": 1}]}],
            [{"total": 2, "data": [{"id": 1}]}, {"total": 2, "data": []}],
            [{"total": 2, "data": [{"id": 1}]}, {"total": 2, "data": [{"id": 1}]}],
            [{"total": 2, "data": [{"id": 1}]}, {"total": 1, "data": []}],
        ):
            client.get_json = mock.Mock(side_effect=responses)
            with self.assertRaises(server.BookStackApiError):
                client.list_pages()
        client.get_json = mock.Mock(side_effect=[{"total": 2, "data": [{"id": 1}]}, {"total": 2, "data": [{"id": 2}]}])
        self.assertEqual([p["id"] for p in client.list_pages()], [1, 2])
        client.settings = mock.Mock(base_url="https://kb.example/bookstack")
        client.get_json = mock.Mock(return_value={"id": 1})
        self.assertEqual(client.read_page(1)["url"], "https://kb.example/bookstack/link/1")
        client.get_json = mock.Mock(return_value={"id": 1, "url": "https://kb.example/original"})
        self.assertEqual(client.read_page(1)["url"], "https://kb.example/original")

    def test_all_scope_uses_one_balanced_total_limit_and_compacts_items(self):
        client = object.__new__(server.BookStackClient)
        calls = []

        def paginated(path, count=500, max_items=0):
            calls.append((path, max_items))
            return [
                {
                    "id": index + 1,
                    "name": f"Item {index + 1}",
                    "url": f"http://bookstack.local{path}/{index + 1}",
                    "description": "x" * 5000,
                    "books": [{"id": nested} for nested in range(100)],
                }
                for index in range(max_items)
            ]

        client.paginated = paginated
        result = client.structure("all", 30)

        self.assertEqual(sum(len(items) for items in result.values()), 30)
        self.assertEqual([limit for _, limit in calls], [8, 8, 7, 7])
        self.assertEqual(list(result), ["shelves", "books", "chapters", "pages"])
        self.assertNotIn("description", result["shelves"][0])
        self.assertNotIn("books", result["shelves"][0])


class EmbeddingClientTests(unittest.TestCase):
    def test_startup_warms_pinned_tokenizer_once_alongside_foreground_access(self):
        with tempfile.TemporaryDirectory() as root:
            settings = replace(make_settings(Path(root) / "cache.sqlite", "qwen/qwen3-embedding-8b"),
                               embedding_api_base="https://example.test/v1", index_on_startup=True)
            service = server.ProductDocsService(settings)
            client = service.embeddings
            entered, waiting, release = threading.Event(), threading.Event(), threading.Event()
            tokenizer = WordTokenizer()

            class WaitingLock:
                def __init__(self):
                    self.lock = threading.Lock()

                def __enter__(self):
                    if threading.current_thread().name != "bookstack-tokenizer-warmup":
                        waiting.set()
                    self.lock.acquire()

                def __exit__(self, *args):
                    self.lock.release()

            def load(*args, **kwargs):
                entered.set()
                if not release.wait(5):
                    raise TimeoutError("test did not release tokenizer loading")
                return tokenizer

            module = types.ModuleType("transformers")
            module.AutoTokenizer = types.SimpleNamespace(from_pretrained=mock.Mock(side_effect=load))
            client._tokenizer_lock = WaitingLock()
            client._remote_batch = mock.Mock(return_value=[[1.0, 0.0]])

            def serve(**kwargs):
                with ThreadPoolExecutor(max_workers=1) as pool:
                    try:
                        self.assertTrue(entered.wait(5))
                        caller = pool.submit(client.tokenizer)
                        self.assertTrue(waiting.wait(5))
                        client._remote_batch.assert_not_called()
                    finally:
                        release.set()
                    self.assertIs(caller.result(timeout=5), tokenizer)

            mcp = mock.Mock()
            mcp.run.side_effect = serve
            with mock.patch.dict(sys.modules, {"transformers": module}), \
                    mock.patch.object(server, "create_mcp", return_value=(mcp, service)), \
                    mock.patch.object(service, "start_background_reindex") as reindex:
                server.main()
                reindex.assert_called_once_with(force=False)
                self.assertEqual(client.embed_query("права пользователя"), [1.0, 0.0])
            module.AutoTokenizer.from_pretrained.assert_called_once_with(
                server.QWEN_TOKENIZER, cache_dir=client.cache_dir, use_fast=True, revision=server.QWEN_REVISION)
            client._remote_batch.assert_called_once_with([
                f"Instruct: {server.QWEN_INSTRUCTION}\nQuery:права пользователя"])

    def test_query_cache_is_bounded_profile_specific_and_returns_independent_vectors(self):
        with tempfile.TemporaryDirectory() as root, mock.patch.object(server, "QUERY_EMBEDDING_CACHE_SIZE", 2):
            client = server.EmbeddingClient(make_settings(Path(root) / "cache.sqlite", "remote-model"))
            client.embed = mock.Mock(return_value=[1.0, 0.0])
            telemetry = {}
            client.embed_query("Заказ", telemetry=telemetry)[0] = 99
            self.assertEqual(telemetry["query_embedding_cache"], "miss")
            telemetry = {}
            self.assertEqual(client.embed_query("Заказ", telemetry=telemetry), [1.0, 0.0])
            self.assertEqual(telemetry["query_embedding_cache"], "hit")
            client.embed_query("договор")
            client.embed_query("Заказ")  # Most recently used, survives the next insertion.
            client.embed_query("проект")
            client.embed_query("Заказ")
            self.assertEqual(client.embed.call_count, 3)
            client.embed_query("договор")
            self.assertEqual(client.embed.call_count, 4)
            client.api_base = "https://another-provider.test/v1"
            client.embed_query("договор")
            self.assertEqual(client.embed.call_count, 5)
            client.model = "another-model"
            client.embed_query("договор")
            self.assertEqual(client.embed.call_count, 6)

    def test_simultaneous_identical_queries_share_success_and_retry_after_failure(self):
        for failure in (False, True):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as root:
                client = server.EmbeddingClient(make_settings(Path(root) / "cache.sqlite", "remote-model"))
                entered, waiting, release = threading.Event(), threading.Event(), threading.Event()

                class WaitingFuture(server.Future):
                    def result(self, timeout=None):
                        waiting.set()
                        return super().result(timeout=5)

                def embed(text):
                    entered.set()
                    if not release.wait(5):
                        raise TimeoutError("test did not release provider")
                    if failure:
                        raise server.BookStackApiError("provider unavailable")
                    return [1.0, 0.0]

                client.embed = mock.Mock(side_effect=embed)
                with mock.patch.object(server, "Future", WaitingFuture), ThreadPoolExecutor(max_workers=2) as pool:
                    first = pool.submit(client.embed_query, "одинаковый запрос")
                    try:
                        self.assertTrue(entered.wait(5))
                        second = pool.submit(client.embed_query, "одинаковый запрос")
                        self.assertTrue(waiting.wait(5))
                    finally:
                        release.set()
                    for result in (first, second):
                        if failure:
                            with self.assertRaisesRegex(server.BookStackApiError, "provider unavailable"):
                                result.result(timeout=5)
                        else:
                            self.assertEqual(result.result(timeout=5), [1.0, 0.0])
                self.assertEqual(client.embed.call_count, 1)
                client.embed.side_effect = None
                client.embed.return_value = [1.0, 0.0]
                self.assertEqual(client.embed_query("одинаковый запрос"), [1.0, 0.0])
                self.assertEqual(client.embed.call_count, 2 if failure else 1)

    def test_multilingual_e5_uses_retrieval_prefixes_and_versioned_storage_key(self):
        with tempfile.TemporaryDirectory() as temp_root:
            settings = make_settings(
                Path(temp_root) / "cache.sqlite",
                embedding_model="intfloat/multilingual-e5-base",
            )
            client = server.EmbeddingClient(settings)
            inputs = []
            client.embed = lambda text: inputs.append(text) or [1.0]

            client.embed_query("заказ")
            client.embed_passage("Документ заказа")

        self.assertEqual(inputs, ["query: заказ", "passage: Документ заказа"])
        self.assertIn("intfloat/multilingual-e5-base::retrieval-v3::", client.storage_model())

    def test_qwen_query_instruction_passage_and_profile(self):
        with tempfile.TemporaryDirectory() as root:
            settings = make_settings(Path(root) / "cache.sqlite", "qwen/qwen3-embedding-8b")
            client = server.EmbeddingClient(settings)
            inputs = []
            client.embed = lambda text: inputs.append(text) or [1.0]
            client.embed_query("права пользователя")
            client.embed_passage("Полный текст документа")
            self.assertEqual(inputs[0], f"Instruct: {server.QWEN_INSTRUCTION}\nQuery:права пользователя")
            self.assertEqual(inputs[1], "Полный текст документа")
            original = client.storage_model()
            client.chunk_tokens = 768
            self.assertNotEqual(original, client.storage_model())
            client.chunk_tokens = 1024
            client.api_base = "https://openrouter.ai/api/v1"
            self.assertNotEqual(original, client.storage_model())

    def test_remote_keeps_full_input_and_rejects_invalid_vectors(self):
        with tempfile.TemporaryDirectory() as root:
            settings = replace(make_settings(Path(root) / "cache.sqlite", "remote-model"), embedding_api_base="https://example.test/v1")
            client = server.EmbeddingClient(settings)
            response = mock.MagicMock()
            response.__enter__.return_value = response
            response.json.side_effect = lambda: json.loads(response.read.return_value)
            response.read.return_value = json.dumps({"data": [{"index": 0, "embedding": [1, 0]}]}).encode()
            text = "полный текст " * 900
            with mock.patch.object(server.httpx.Client, "post", return_value=response) as call:
                self.assertEqual(client.embed_remote(text), [1, 0])
                self.assertEqual(call.call_args.kwargs["json"]["input"], text)
                for vector in ([], [0, 0], [float("nan"), 1], [float("inf")]):
                    response.read.return_value = json.dumps({"data": [{"embedding": vector}]}).encode()
                    with self.assertRaises(ValueError):
                        client.embed_remote("query")

    def test_openrouter_latency_routing_preserves_model_input_and_other_backends(self):
        model = "qwen/qwen3-embedding-8b"
        with tempfile.TemporaryDirectory() as root:
            for base in ("https://openrouter.ai/api/v1", "https://example.test/v1",
                         "https://openrouter.ai.example.test/v1"):
                with self.subTest(base=base):
                    settings = replace(make_settings(Path(root)/"cache.sqlite", model), embedding_api_base=base)
                    client = server.EmbeddingClient(settings)
                    response = mock.MagicMock()
                    response.__enter__.return_value = response
                    response.json.side_effect = lambda: json.loads(response.read.return_value)
                    response.read.return_value = json.dumps({"model": model, "data": [
                        {"index": 0, "embedding": [1.0] + [0.0] * 4095}]}).encode()
                    text = "Instruct: retrieval\nQuery:права пользователя"
                    with mock.patch.object(server.httpx.Client, "post", return_value=response) as call:
                        self.assertEqual(len(client.embed_remote(text)), 4096)
                        body = call.call_args.kwargs["json"]
                    self.assertEqual(body["model"], model)
                    self.assertEqual(body["input"], text)
                    self.assertEqual(body["encoding_format"], "float")
                    if base == "https://openrouter.ai/api/v1":
                        self.assertEqual(body["provider"], {"sort": "latency"})
                    else:
                        self.assertNotIn("provider", body)

    def test_remote_reuses_client_and_retries_only_failed_connections(self):
        with tempfile.TemporaryDirectory() as root:
            settings = replace(make_settings(Path(root)/"cache.sqlite", "remote-model"),
                               embedding_api_base="https://example.test/v1")
            client = server.EmbeddingClient(settings)
            remote = mock.Mock()
            response = mock.Mock()
            response.json.return_value = {"data": [{"index": 0, "embedding": [1, 0]}]}
            remote.post.side_effect = [server.httpx.ConnectError("TLS interrupted"), response, response]
            with mock.patch.object(server.httpx, "Client", return_value=remote) as factory:
                self.assertEqual(client.embed_remote("first complete input"), [1, 0])
                self.assertEqual(client.embed_remote("second complete input"), [1, 0])
                factory.assert_called_once()
                self.assertEqual(remote.post.call_count, 3)
                self.assertEqual([call.kwargs["json"]["input"] for call in remote.post.call_args_list],
                                 ["first complete input", "first complete input", "second complete input"])
                remote.post.reset_mock(side_effect=True)
                remote.post.side_effect = [server.httpx.ConnectError("secret-marker")] * 2
                with self.assertRaises(server.BookStackApiError) as failure:
                    client.embed_remote("third input")
                self.assertEqual(remote.post.call_count, 2)
                self.assertNotIn("secret-marker", str(failure.exception))
                remote.post.reset_mock(side_effect=True)
                remote.post.side_effect = server.httpx.ReadTimeout("late response")
                with self.assertRaises(server.BookStackApiError):
                    client.embed_remote("fourth input")
                self.assertEqual(remote.post.call_count, 1)

    def test_qwen_dimension_and_default_threshold(self):
        with mock.patch.dict(os.environ, {"BOOKSTACK_EMBEDDING_MODEL": "qwen/qwen3-embedding-8b", "BOOKSTACK_SEMANTIC_MIN_SCORE": ""}):
            self.assertEqual(server.Settings.from_env().semantic_min_score, server.QWEN_MIN_SCORE)
        with tempfile.TemporaryDirectory() as root:
            client = server.EmbeddingClient(make_settings(Path(root)/"cache.sqlite", "qwen/qwen3-embedding-8b"))
            response = mock.MagicMock()
            response.__enter__.return_value = response
            response.json.side_effect = lambda: json.loads(response.read.return_value)
            response.read.return_value = json.dumps({"data": [{"embedding": [1, 0]}]}).encode()
            with mock.patch.object(server.httpx.Client, "post", return_value=response), self.assertRaises(ValueError):
                client.embed_remote("query")

    def test_batch_reorders_complete_indices_and_rejects_missing_duplicate_indices(self):
        with tempfile.TemporaryDirectory() as root:
            client = server.EmbeddingClient(replace(make_settings(Path(root)/"cache.sqlite", "remote-model"), embedding_api_base="https://example.test/v1"))
            response = mock.MagicMock()
            response.json.side_effect = lambda: json.loads(response.read.return_value)
            response.__enter__.return_value = response
            with mock.patch.object(server.httpx.Client, "post", return_value=response):
                response.read.return_value = json.dumps({"data": [{"index": 1, "embedding": [0, 1]}, {"index": 0, "embedding": [1, 0]}]}).encode()
                self.assertEqual(client._remote_batch(["first", "second"]), [[1, 0], [0, 1]])
                response.read.return_value = json.dumps({"data": [{"index": 0, "embedding": [0, 1]}, {"index": 0, "embedding": [1, 0]}]}).encode()
                with self.assertRaises(server.BookStackApiError):
                    client._remote_batch(["first", "second"])


class FragmentIndexTests(unittest.TestCase):
    def service(self, root, pages):
        service = server.ProductDocsService(make_settings(Path(root) / "кэш с пробелом.sqlite"))
        service.client = FakeClient(pages)
        service.embeddings = FakeEmbeddings()
        return service

    def test_structure_preserves_blocks_and_full_unicode_tail(self):
        table = "| поле | значение |\n" + "| срок | месяц |\n" * 5
        listing = "- пункт первый\n- пункт второй\n"
        text = "# Начало\n\n" + "вступление " * 35 + "\n\n" + table + "\n" + listing + "\n## Конец\n\n" + "заключение " * 400 + "🚀хвост"
        chunks = server.fragments(text, "Название", WordTokenizer(), 64, 4)
        self.assertTrue(any(table in chunk["input"] for chunk in chunks))
        self.assertTrue(any(listing in chunk["input"] for chunk in chunks))
        self.assertTrue(all(chunk["tokens"] <= 64 for chunk in chunks))
        covered = set()
        for chunk in chunks:
            covered.update(range(chunk["start"], chunk["end"]))
        self.assertEqual(covered, set(range(len(text))))
        self.assertTrue(chunks[-1]["input"].endswith("🚀хвост"))
        self.assertEqual(chunks[-1]["heading"], "Начало / Конец")

    def test_html_headings_and_lists_survive_normalization(self):
        text = server.html_to_text("<h1>Права</h1><p>Введение</p><h2>Назначения</h2><ul><li>Первый</li><li>Второй</li></ul><table><tr><td><p>Роль</p></td><td>Автор</td></tr></table><script>secret script</script>")
        chunks = server.fragments(text, "Документ", WordTokenizer(), 64)
        self.assertEqual(chunks[-1]["heading"], "Права / Назначения")
        self.assertIn("- Первый", chunks[-1]["input"])
        self.assertIn("Роль", chunks[-1]["input"])
        self.assertNotIn("secret script", text)
        self.assertNotIn("Роль\n\n", text)

    def test_fenced_headings_are_not_sections_and_interrupted_state_survives_restart(self):
        text = "# Intro\n\n```python\n# not a heading\n\nprint(1)\n```\n\n# Final\n\ntext"
        chunks = server.fragments(text, "Title", WordTokenizer(), 64)
        self.assertEqual([chunk["heading"] for chunk in chunks], ["Intro", "Final"])
        with tempfile.TemporaryDirectory() as root:
            service = self.service(root, [page(1, text)])
            service.reindex_docs()
            service.fragment_index.state(in_progress=True)
            restarted = self.service(root, [page(1, text)])
            self.assertFalse(restarted.index_status()["semantic_ready"])
            self.assertTrue(restarted.reindex_docs()["coverage"]["semantic_ready"])
            self.assertEqual(restarted.embeddings.passage_inputs, [])

    def test_failed_page_resumes_saved_vectors_and_never_publishes_partial(self):
        item = page(1, "# Введение\n\n" + " ".join(f"слово{i}" for i in range(1000)) + "\n\n# Финал\n\nконец")
        with tempfile.TemporaryDirectory() as root:
            service = self.service(root, [item])
            original = service.embeddings.embed_passages
            calls = 0
            def flaky(text):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise RuntimeError("provider unavailable")
                return original(text)
            service.embeddings.embed_passages = flaky
            failed = service.reindex_docs()
            self.assertFalse(failed["ok"])
            self.assertEqual(service.index_status()["ready_pages"], 0)
            self.assertEqual(list(service.fragment_index.all_vectors(service.embeddings.storage_model())), [])
            resumed = self.service(root, [item])
            result = resumed.reindex_docs()
            self.assertTrue(result["coverage"]["semantic_ready"])
            self.assertEqual(len(resumed.embeddings.passage_inputs), result["coverage"]["fragments"] - 8)
            with resumed.cache.connect() as reader:
                reader.execute("BEGIN")
                reader.execute("SELECT vector_json FROM fragment_vectors").fetchone()
                usage = resumed.fragment_index.usage(resumed.embeddings.storage_model(), {"prompt_tokens": 3})
                self.assertEqual(usage["tokens"], 3)
            resumed.reindex_docs(force=True)
            self.assertEqual(len(resumed.embeddings.passage_inputs), result["coverage"]["fragments"] - 8)

    def test_changed_section_reuses_other_sections_title_invalidates_and_delete_reconciles(self):
        items = [page(1, "# A\n\nfirst section\n\n# B\n\nsecond section"), page(2, ""), page(3, "third")]
        with tempfile.TemporaryDirectory() as root:
            service = self.service(root, items)
            service.reindex_docs()
            self.assertEqual(service.index_status()["empty_pages"], 1)
            vectors = lambda: list(service.fragment_index.all_vectors(service.embeddings.storage_model()))
            self.assertEqual({p["id"] for p, _ in vectors()}, {1, 3})
            before = len(service.embeddings.passage_inputs)
            items[0]["markdown"] = items[0]["markdown"].replace("second", "changed")
            service.reindex_docs(force=True)
            self.assertEqual(len(service.embeddings.passage_inputs), before + 1)
            self.assertFalse(any("second section" in p["fragment_text"] for p, _ in vectors()))
            items[0]["name"] = "Renamed 1"
            service.reindex_docs()
            self.assertEqual(len(service.embeddings.passage_inputs), before + 3)
            self.assertEqual({p["name"] for p, _ in vectors() if p["id"] == 1}, {"Renamed 1"})
            del service.client.pages[3]
            service.reindex_docs(limit=1)
            self.assertEqual(service.cache.count_pages(), 3)
            self.assertFalse(service.index_status()["semantic_ready"])
            self.assertEqual(service.reindex_docs()["deleted"], 1)
            self.assertEqual(service.cache.count_pages(), 2)
            self.assertEqual(service.cache.search("third", 20, {}), [])
            self.assertEqual({p["id"] for p, _ in vectors()}, {1})

    def test_middle_and_end_are_found_without_duplicate_pages(self):
        item = page(1, "# Start\n\n" + "beginning " * 1500 + "\n\n# Middle\n\nmiddle marker\n\n# End\n\nfinal marker")
        with tempfile.TemporaryDirectory() as root:
            service = self.service(root, [item, page(2, "unrelated")])
            service.embeddings.embed_passage = lambda text: [1, 0, 0] if "final marker" in text else ([0, 1, 0] if "middle marker" in text else [0, 0, 1])
            service.embeddings.embed_query = lambda query: [1, 0, 0] if query == "last topic" else [0, 1, 0]
            service.reindex_docs()
            for query, heading in (("last topic", "End"), ("interior topic", "Middle")):
                result = service.search_docs(query, None, 5)
                self.assertEqual([row["id"] for row in result["results"]], [1])
                self.assertEqual(result["results"][0]["fragment"]["heading"], heading)
                self.assertGreater(result["results"][0]["fragment"]["start"], 6000)

    def test_legacy_backup_is_readable_and_bad_inventory_preserves_pages(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "кэш с пробелом.sqlite"
            cache = server.DocsCache(str(path))
            cache.upsert_page(page(1, "legacy"), "legacy", "", "legacy")
            cache.upsert_embedding(1, "e5", "legacy-hash", [1, 0])
            service = self.service(root, [])
            backup = server.DocsCache(str(path) + ".pre-fragments.sqlite")
            self.assertEqual(backup.get_page(1)["content_text"], "legacy")
            with backup.connect() as conn:
                self.assertEqual(conn.execute("select count(*) from embeddings").fetchone()[0], 1)
            service.client.list_pages = mock.Mock(side_effect=RuntimeError("source unavailable"))
            with self.assertRaises(RuntimeError):
                service.reindex_docs()
            self.assertEqual(service.cache.count_pages(), 1)
            self.assertFalse(service.index_status()["semantic_ready"])

    def test_read_does_not_wait_for_reindex_and_survives_provider_failure(self):
        with tempfile.TemporaryDirectory() as root:
            service = self.service(root, [page(1, "fresh content")])
            locked, release = threading.Event(), threading.Event()
            def worker():
                with service._index_lock:
                    locked.set()
                    release.wait(5)
            thread = threading.Thread(target=worker)
            thread.start()
            try:
                self.assertTrue(locked.wait(2))
                self.assertFalse(service.reindex_docs()["ok"])
                result = service.read_page(1, "", "text")
                self.assertEqual(result["content"], "fresh content")
            finally:
                release.set()
                thread.join()
            service.embeddings.embed_passages = mock.Mock(side_effect=RuntimeError("provider down"))
            self.assertEqual(service.read_page(1, "", "text")["content"], "fresh content")
            self.assertFalse(service.index_status()["semantic_ready"])


class CosineScoreTests(unittest.TestCase):
    def test_batch_scores_preserve_cosine_including_zero_and_mismatched_vectors(self):
        query = [0.6, 0.8]
        vectors = [[0.6, 0.8], [0.8, -0.6], [0.0, 0.0], [0.6], [-0.6, -0.8]]
        expected = [server.cosine_similarity(query, vector) for vector in vectors]
        if server.np is not None:
            with mock.patch.object(server, "cosine_similarity", side_effect=AssertionError("batch path expected")):
                actual = server.cosine_scores(query, vectors)
            for score, old_score in zip(actual, expected):
                self.assertAlmostEqual(score, old_score, places=12)
        with mock.patch.object(server, "np", None):
            self.assertEqual(server.cosine_scores(query, vectors), expected)


class ProductDocsServiceTests(unittest.TestCase):
    def make_service(self, temp_root, pages):
        service = server.ProductDocsService(make_settings(Path(temp_root) / "cache.sqlite"))
        service.client = FakeClient(pages)
        return service

    def test_search_returns_five_compact_results_by_default(self):
        pages = [page(index, f"Architecture decision {index}. " + "detail " * 200) for index in range(1, 9)]
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            for item in pages:
                service.index_page(item)
            result = service.search_docs("Architecture", filters=None, limit=server.DEFAULT_SEARCH_LIMIT)

        self.assertTrue(result["ok"])
        self.assertEqual(result["result_count"], 5)
        self.assertEqual(result["total_matches"], 8)
        self.assertEqual(result["cursor"], 0)
        self.assertEqual(result["next_cursor"], 5)
        self.assertTrue(result["has_more"])
        self.assertEqual(len(result["results"]), 5)
        self.assertNotIn("cache_pages", result)
        self.assertNotIn("embedding_enabled", result)
        self.assertNotIn("name", result["results"][0])
        self.assertNotIn("indexed_at", result["results"][0])
        self.assertLessEqual(len(result["results"][0]["preview"]), server.SEARCH_PREVIEW_CHARS + 6)
        self.assertLess(len(json.dumps(result, ensure_ascii=False)), 6000)
        self.assertIn("next_cursor=5", server.tool_result_summary("search", result))

    def test_search_diagnostics_report_stages_and_query_cache_only_on_request(self):
        pages = [page(1, "Architecture decision."), page(2, "Architecture detail.")]
        with tempfile.TemporaryDirectory() as root:
            service = self.make_service(root, pages)
            service.embeddings = server.EmbeddingClient(make_settings(Path(root) / "cache.sqlite", "fake-model"))
            service.embeddings._tokenizer = WordTokenizer()
            service.embeddings.embed = mock.Mock(return_value=[1.0, 0.0])
            for item in pages:
                service.index_page(item)
            service.embeddings.embed.reset_mock()
            first = service.search_docs("Architecture", None, 5, diagnostics=True)
            second = service.search_docs("Architecture", None, 5, diagnostics=True)
            plain = service.search_docs("Architecture", None, 5)
            text = service.search_docs("Architecture", None, 5, mode="text", diagnostics=True)

        self.assertEqual(service.embeddings.embed.call_count, 1)
        self.assertEqual([item["id"] for item in first["results"]], [item["id"] for item in plain["results"]])
        self.assertNotIn("diagnostics", plain)
        self.assertEqual(first["diagnostics"]["query_embedding_cache"], "miss")
        self.assertEqual(second["diagnostics"]["query_embedding_cache"], "hit")
        self.assertEqual(first["diagnostics"]["scored_fragments"], 2)
        for field in ("text_ms", "query_embedding_ms", "vector_scoring_ms", "ranking_ms", "total_ms"):
            self.assertGreaterEqual(first["diagnostics"][field], 0)
        self.assertEqual(text["diagnostics"]["query_embedding_cache"], "not_requested")
        self.assertEqual(text["diagnostics"]["vector_scoring_ms"], 0.0)

    def test_embedding_failure_reports_query_degradation_without_marking_index_incomplete(self):
        with tempfile.TemporaryDirectory() as root:
            service = self.make_service(root, [page(1, "Architecture decision.")])
            service.embeddings = server.EmbeddingClient(make_settings(Path(root) / "cache.sqlite", "fake-model"))
            service.embeddings._tokenizer = WordTokenizer()
            service.embeddings.embed = mock.Mock(return_value=[1.0, 0.0])
            service.reindex_docs()
            service.embeddings.embed = mock.Mock(side_effect=server.BookStackApiError("Embedding request failed (HTTP 429)"))
            result = service.search_docs("Architecture", None, 5, diagnostics=True)
            status = service.index_status()

        self.assertEqual(result["semantic_status"], "degraded")
        self.assertIn("provider recovers", result["semantic_continuation"])
        self.assertIn("HTTP 429", result["diagnostics"]["embedding_error"])
        self.assertIn("query_embedding_ms", result["diagnostics"])
        self.assertEqual([row["id"] for row in result["results"]], [1])
        self.assertTrue(status["semantic_ready"])

    def test_text_search_works_without_embeddings_including_live_fallback_and_pagination(self):
        pages = [page(index, "Точный термин в середине документа.") for index in range(1, 8)]
        with tempfile.TemporaryDirectory() as root:
            service = self.make_service(root, pages)
            for item in pages:
                service.index_page(item)
            service.embeddings = FakeEmbeddings()
            service.embeddings.embed_query = mock.Mock(side_effect=AssertionError("text must not embed"))
            service.last_embedding_error = "previous provider outage"
            first = service.search_docs("Точный термин", None, 3, mode="text")
            second = service.search_docs("Точный термин", None, 3, first["next_cursor"], mode="text")
            absent = service.search_docs("отсутствующий термин", None, 3, mode="text")
            self.assertEqual(first["mode"], "text")
            self.assertEqual(first["total_matches"], 7)
            self.assertFalse({p["id"] for p in first["results"]} & {p["id"] for p in second["results"]})
            self.assertNotIn("semantic_status", first)
            self.assertEqual(absent["results"], [])
            self.assertEqual(len(service.client.search_calls), 1)
            service.embeddings.embed_query.assert_not_called()

    def test_semantic_mode_does_not_return_lexical_fallback_and_unknown_mode_does_not_search(self):
        with tempfile.TemporaryDirectory() as root:
            service = self.make_service(root, [page(1, "exact keyword")])
            service.embeddings = LowConfidenceEmbeddings()
            service.index_page(service.client.pages[1])
            result = service.search_docs("exact keyword", {"live": True}, 5, mode="semantic")
            self.assertEqual(result["results"], [])
            self.assertEqual(result["mode"], "semantic")
            with mock.patch.object(service, "semantic_results") as semantic:
                invalid = service.search_docs("exact keyword", None, 5, mode="typo")
                self.assertFalse(invalid["ok"])
                semantic.assert_not_called()
            self.assertEqual(service.client.search_calls, [])

    def test_cached_query_reuses_embedding_across_cursors_and_filters_but_refreshes_results(self):
        pages = [page(index, "Architecture decision.") for index in range(1, 8)]
        with tempfile.TemporaryDirectory() as root:
            service = self.make_service(root, pages)
            service.embeddings = server.EmbeddingClient(make_settings(Path(root) / "cache.sqlite", "fake-model"))
            service.embeddings._tokenizer = WordTokenizer()
            service.embeddings.embed = mock.Mock(return_value=[1.0, 0.0])
            for item in pages:
                service.index_page(item)
            service.embeddings.embed.reset_mock()
            first = service.search_docs("Architecture", None, 3)
            second = service.search_docs("Architecture", None, 3, first["next_cursor"])
            filtered = service.search_docs("Architecture", {"book": "Missing book"}, 3)
            self.assertEqual(service.embeddings.embed.call_count, 1)
            self.assertEqual(first["mode"], "hybrid")
            self.assertFalse({p["id"] for p in first["results"]} & {p["id"] for p in second["results"]})
            self.assertEqual(filtered["results"], [])
            changed = dict(pages[0], name="Architecture updated", markdown="New current content.")
            service.index_page(changed)
            service.embeddings.embed.reset_mock()
            refreshed = service.search_docs("Architecture", None, 20)
            self.assertEqual(next(p for p in refreshed["results"] if p["id"] == 1)["title"], "Architecture updated")
            service.embeddings.embed.assert_not_called()

    def test_search_cursor_pages_through_all_results_without_repeating_items(self):
        pages = [page(index, f"Architecture decision {index}.") for index in range(1, 13)]
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            for item in pages:
                service.index_page(item)
            first = service.search_docs("Architecture", filters=None, limit=5)
            second = service.search_docs("Architecture", filters=None, limit=5, cursor=first["next_cursor"])
            final = service.search_docs("Architecture", filters=None, limit=5, cursor=second["next_cursor"])

        result_ids = [item["id"] for result in (first, second, final) for item in result["results"]]
        self.assertEqual(len(result_ids), 12)
        self.assertEqual(len(set(result_ids)), 12)
        self.assertEqual(second["cursor"], 5)
        self.assertEqual(second["next_cursor"], 10)
        self.assertEqual(final["cursor"], 10)
        self.assertEqual(final["result_count"], 2)
        self.assertEqual(final["total_matches"], 12)
        self.assertFalse(final["has_more"])
        self.assertIsNone(final["next_cursor"])

    def test_search_rejects_negative_cursor(self):
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, [])
            result = service.search_docs("Architecture", filters=None, limit=5, cursor=-1)

        self.assertFalse(result["ok"])
        self.assertIn("cursor", result["error"])

    def test_multi_term_search_requires_every_term_and_does_not_fill_partial_results_live(self):
        pages = [
            page(1, "Обмен знаниями."),
            page(2, "Модель данных."),
            page(3, "Обмен данными между системами."),
        ]
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            for item in pages:
                service.index_page(item)
            result = service.search_docs("обмен данными", filters=None, limit=5)

        self.assertEqual([item["id"] for item in result["results"]], [3])
        self.assertEqual(service.client.search_calls, [])

    def test_low_confidence_semantic_results_are_not_returned_as_matches(self):
        pages = [page(index, f"Product detail {index}.") for index in range(1, 6)]
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            service.embeddings = LowConfidenceEmbeddings()
            for item in pages:
                service.index_page(item)
            result = service.search_docs("unrelated semantic query", filters=None, limit=5)

        self.assertEqual(result["total_matches"], 0)
        self.assertEqual(result["results"], [])
        self.assertEqual(len(service.client.search_calls), 1)

    def test_confident_semantic_match_outranks_distributed_lexical_terms(self):
        pages = [
            page(1, "Обмен знаниями и модель с данными проекта."),
            page(2, "Трансляция экономической информации между системами."),
        ]
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            service.embeddings = RankingEmbeddings()
            for item in pages:
                service.index_page(item)
            result = service.search_docs("обмен данными", filters=None, limit=5)

        self.assertEqual([item["id"] for item in result["results"]], [2, 1])
        self.assertGreater(result["results"][0]["semantic_score"], server.DEFAULT_SEMANTIC_MIN_SCORE)

    def test_semantic_search_uses_a_bounded_candidate_set(self):
        pages = [page(index, f"Product detail {index}.") for index in range(1, 31)]
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            service.embeddings = FakeEmbeddings()
            for item in pages:
                service.index_page(item)
            first = service.search_docs("term absent from every page", filters=None, limit=5)
            final = service.search_docs("term absent from every page", filters=None, limit=5, cursor=15)

        self.assertEqual(first["total_matches"], server.MAX_SEMANTIC_CANDIDATES)
        self.assertEqual(first["result_count"], 5)
        self.assertEqual(first["next_cursor"], 5)
        self.assertEqual(final["result_count"], 5)
        self.assertIsNone(final["next_cursor"])
        self.assertFalse(final["has_more"])

    def test_exact_search_match_stays_ahead_of_semantic_only_candidates(self):
        pages = [page(index, f"Product detail {index}.") for index in range(1, 31)]
        pages[-1]["markdown"] += " unique-needle"
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            service.embeddings = FakeEmbeddings()
            for item in pages:
                service.index_page(item)
            result = service.search_docs("unique-needle", filters=None, limit=5)

        self.assertEqual(result["results"][0]["id"], 30)
        self.assertIn("unique-needle", result["results"][0]["preview"])

    def test_plan_editor_inflections_find_the_architecture_page(self):
        generic = page(1, "Редактор планов поддерживает параллельную работу пользователей.")
        generic["name"] = "Редактор планов. Возможности"
        architecture = page(2, "Механизм параллельной работы используется в редакторе планов.")
        architecture["name"] = "Обзор архитектуры многопользовательской работы"
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, [generic, architecture])
            service.index_page(generic)
            service.index_page(architecture)
            for query in ("параллельная работа редактор планов",
                          "многопользовательская работа редактор планов"):
                with self.subTest(query=query):
                    result = service.search_docs(query, None, 5, mode="text")
                    self.assertIn(2, [p["id"] for p in result["results"][:3]])

    def test_russian_inflections_work_across_topics_and_keep_identifiers_exact(self):
        cases = [
            ("Распределение ресурсов", ("распределение ресурсами", "распределения ресурса")),
            ("Согласование бюджетов", ("согласовании бюджета", "согласование бюджетами")),
            ("Расчет себестоимости", ("расчетом себестоимость", "расчета себестоимости")),
            ("Назначение ролей", ("назначения ролями", "назначении роли")),
            ("Изменение сроков", ("изменения срока", "изменении сроками")),
        ]
        pages = [dict(page(i, title), name=title) for i, (title, _) in enumerate(cases, 1)]
        pages += [page(6, "PM500 упо_РасчетСроковДополнение ОСАГО"),
                  page(7, "PM5 упо_РасчетСроков ОС")]
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            for item in pages:
                service.index_page(item)
            for i, (_, queries) in enumerate(cases, 1):
                for query in queries:
                    with self.subTest(query=query):
                        result = service.search_docs(query, None, 5, mode="text")
                        self.assertEqual([p["id"] for p in result["results"]], [i])
            for query in ("PM5", "упо_РасчетСроков", "ОС"):
                with self.subTest(query=query):
                    self.assertEqual([p["id"] for p in service.cache.search(query, 5, {})], [7])

    def test_hybrid_retains_bm25_evidence_and_semantic_mode_retains_cosine_order(self):
        pages = [page(1, "Обмен сведениями, включая данные проекта."),
                 page(2, "Экономическая информация между системами.")]
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            service.embeddings = RankingEmbeddings()
            # Both documents pass the semantic threshold; page 2 is the cosine
            # leader, but only page 1 matches the lexical query in the first run.
            service.settings = replace(service.settings, semantic_min_score=0.5)
            for item in pages:
                service.index_page(item)
            hybrid = service.search_docs("обмен данными", None, 1)
            continuation = service.search_docs("обмен данными", None, 1, cursor=hybrid["next_cursor"])
            semantic = service.search_docs("обмен данными", None, 5, mode="semantic")
            self.assertEqual([hybrid["results"][0]["id"], continuation["results"][0]["id"]], [1, 2])
            self.assertEqual([p["id"] for p in semantic["results"]], [2, 1])
            self.assertFalse(any(k.startswith("_") for k in hybrid["results"][0]))

    def test_background_warm_primes_vectors_before_first_search(self):
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, [page(1, "Product architecture detail.")])
            service.embeddings = FakeEmbeddings()
            service.index_page(page(1, "Product architecture detail."))
            self.assertIsNone(service.fragment_index._search_cache[1])
            worker = service.start_background_warm()
            self.assertIsNotNone(worker)
            worker.join(2)
            self.assertFalse(worker.is_alive())
            self.assertEqual(len(service.fragment_index._search_cache[1]), 1)
            self.assertEqual(service.search_docs("Product", None, 5)["results"][0]["id"], 1)

    def test_reindex_refreshes_unchanged_pages_when_embedding_profile_changes(self):
        pages = [page(1, "Architecture decision.")]
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            service.embeddings = FakeEmbeddings(profile="fake-model::old-profile")
            service.index_page(pages[0])
            service.embeddings.profile = "fake-model::retrieval-v2"
            result = service.reindex_docs(force=False)
            status = service.index_status()

        self.assertEqual(result["indexed"], 1)
        self.assertEqual(result["skipped"], 0)
        self.assertEqual(status["embedded_pages"], 1)
        self.assertEqual(status["embedding_profile"], "fake-model::retrieval-v2")

    def test_read_page_returns_query_window_and_cursor_instead_of_full_page(self):
        body = "# Intro\n" + ("intro text\n" * 2500) + "\n# Critical section\nneedle decision\n" + ("detail\n" * 2500)
        item = page(1, body)
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, [item])
            default_window = service.read_page(1, "", "markdown")
            result = service.read_page(1, "", "markdown", query="needle decision", max_chars=1000)
            full = service.read_page(1, "", "markdown", max_chars=0)

        self.assertEqual(len(default_window["content"]), server.DEFAULT_PAGE_MAX_CHARS)
        self.assertTrue(default_window["truncated"])
        self.assertTrue(result["ok"])
        self.assertEqual(result["selection"], "query")
        self.assertTrue(result["match_found"])
        self.assertIn("needle decision", result["content"])
        self.assertLessEqual(len(result["content"]), 1000)
        self.assertTrue(result["truncated"])
        self.assertIsNotNone(result["next_cursor"])
        summary = server.tool_result_summary("read", result)
        self.assertIn("1000/", summary)
        self.assertNotIn("needle decision", summary)
        self.assertGreater(full["total_chars"], server.DEFAULT_PAGE_MAX_CHARS)
        self.assertFalse(full["truncated"])

    def test_read_page_selects_markdown_heading_and_reports_missing_heading(self):
        body = "# Intro\nintro\n\n## Selected section\nselected text\n\n## Following section\nother text"
        item = page(1, body)
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, [item])
            selected = service.read_page(1, "", "markdown", heading="Selected", max_chars=1000)
            missing = service.read_page(1, "", "markdown", heading="Missing", max_chars=1000)

        self.assertTrue(selected["ok"])
        self.assertIn("selected text", selected["content"])
        self.assertNotIn("other text", selected["content"])
        self.assertFalse(missing["ok"])
        self.assertIn("Selected section", missing["available_headings"])

    def test_structure_rejects_invalid_scope_and_caps_the_limit(self):
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, [])
            invalid = service.list_structure("invalid", 10)
            capped = service.list_structure("pages", 1000)

        self.assertFalse(invalid["ok"])
        self.assertEqual(capped["limit"], server.MAX_STRUCTURE_LIMIT)
        self.assertEqual(capped["result_count"], server.MAX_STRUCTURE_LIMIT)
        self.assertLess(len(json.dumps(capped, ensure_ascii=False)), 30000)


if __name__ == "__main__":
    unittest.main(testRunner=unittest.TextTestRunner(stream=sys.stdout))
