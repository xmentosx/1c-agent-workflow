"""Build-time edits for the exact qualified Cognee wheel."""

import hashlib
from importlib.metadata import distribution
from pathlib import Path


def replace(source, before, after):
    if source.count(before) != 1:
        raise RuntimeError("Cognee patch anchor is missing or ambiguous")
    return source.replace(before, after, 1)


def patch_router(source):
    source = replace(
        source,
        "from cognee.shared.logging_utils import get_logger\n",
        "from cognee.shared.itl_recall_policy import RecallDeadlineExceeded, run_chunks_recall\n"
        "from cognee.shared.logging_utils import get_logger\n",
    )
    return replace(
        source,
        "            results = await _run_recall()\n"
        "            return jsonable_encoder(results)\n",
        "            if payload.search_type == SearchType.CHUNKS:\n"
        "                results = await run_chunks_recall(_run_recall)\n"
        "            else:\n"
        "                results = await _run_recall()\n"
        "            return jsonable_encoder(results)\n"
        "        except RecallDeadlineExceeded:\n"
        "            get_logger().warning(\"Cognee CHUNKS recall exceeded its deadline\")\n"
        "            return JSONResponse(\n"
        "                status_code=504, content={\"detail\": \"Cognee recall deadline exceeded\"}\n"
        "            )\n",
    )


def patch_lancedb(source):
    anchor = "from cognee.infrastructure.databases.vector.exceptions import CollectionNotFoundError\n"
    source = replace(
        source,
        anchor,
        anchor
        + "from cognee.shared.itl_recall_policy import embed_chunk_query, use_early_collection_lookup\n",
    )
    return replace(
        source,
        "            if query_text and not query_vector:\n"
        "                query_vector = (await self.embedding_engine.embed_text([query_text]))[0]\n"
        "\n"
        "            collection = await self.get_collection(collection_name)\n",
        "            if query_text and not query_vector:\n"
        "                if use_early_collection_lookup(collection_name):\n"
        "                    collection = await self.get_collection(collection_name)\n"
        "                    query_vector = await embed_chunk_query(self.embedding_engine, query_text)\n"
        "                else:\n"
        "                    query_vector = (await self.embedding_engine.embed_text([query_text]))[0]\n"
        "                    collection = await self.get_collection(collection_name)\n"
        "            else:\n"
        "                collection = await self.get_collection(collection_name)\n",
    )


def patch_embedding_engine(source):
    anchor = "from cognee.shared.rate_limiting import embedding_rate_limiter_context_manager\n"
    source = replace(
        source,
        anchor,
        anchor
        + "from cognee.shared.itl_recall_policy import apply_query_request_options, embedding_http_client\n",
    )
    source = replace(
        source,
        "        self._client = AsyncOpenAI(api_key=self.api_key, base_url=base, timeout=120)\n",
        "        self._client = AsyncOpenAI(\n"
        "            api_key=self.api_key, base_url=base, timeout=120, http_client=embedding_http_client()\n"
        "        )\n",
    )
    return replace(
        source,
        "                create_kwargs[\"extra_body\"] = {\"input_type\": self.input_type}\n"
        "\n"
        "            async with embedding_rate_limiter_context_manager():\n",
        "                create_kwargs[\"extra_body\"] = {\"input_type\": self.input_type}\n"
        "            create_kwargs = apply_query_request_options(self.endpoint, create_kwargs)\n"
        "\n"
        "            async with embedding_rate_limiter_context_manager():\n",
    )


def main():
    wheel = distribution("cognee")
    if wheel.version != "1.6.5":
        raise RuntimeError(f"Expected Cognee 1.6.5, found {wheel.version}")
    sources = [
        (
            "cognee/api/v1/recall/routers/get_recall_router.py",
            "e016d99b8645d3fff53303a1f41bca905cc5e5bcedf8e1db1b8536a2edc74ee6",
            patch_router,
        ),
        (
            "cognee/infrastructure/databases/vector/lancedb/LanceDBAdapter.py",
            "7bd305e55836a73c6840de9cc5669d6482a4dbd0075a9ac1ff057318605f8a4f",
            patch_lancedb,
        ),
        (
            "cognee/infrastructure/databases/vector/embeddings/OpenAICompatibleEmbeddingEngine.py",
            "f79dcb9c076bf66c0193e439d26a478a9b03d6958ec925f5348f209552d68ea7",
            patch_embedding_engine,
        ),
    ]
    edits = {}
    for name, expected_sha256, patch in sources:
        path = wheel.locate_file(name)
        raw = path.read_bytes()
        if hashlib.sha256(raw).hexdigest() != expected_sha256:
            raise RuntimeError(f"Unexpected Cognee source at {name}")
        edits[path] = patch(raw.decode("utf-8"))
    policy = wheel.locate_file("cognee/shared/itl_recall_policy.py")
    if policy.exists():
        raise RuntimeError("Recall policy already exists in the base image")
    edits[policy] = Path(__file__).with_name("recall_policy.py").read_text(encoding="utf-8")
    for path, source in edits.items():
        compile(source, str(path), "exec")
    for path, source in edits.items():
        path.write_text(source, encoding="utf-8")


if __name__ == "__main__":
    main()
