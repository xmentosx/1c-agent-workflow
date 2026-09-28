"""Explicit maintainer acceptance probe; never scheduled or exposed as an MCP tool."""
import argparse
import json
import time
from dataclasses import replace
from pathlib import Path

import server


def audit_coverage(service):
    if not hasattr(service, "fragment_index"):
        return None
    profile = service.embeddings.storage_model()
    tokenizer = service.embeddings.tokenizer()
    max_tokens = total_tokens = chunks = chars = 0
    with service.cache.connect() as conn:
        pages = conn.execute("SELECT * FROM pages ORDER BY id").fetchall()
        for page in pages:
            mappings = conn.execute("SELECT * FROM fragments WHERE page_id=? ORDER BY ordinal", (page["id"],)).fetchall()
            ready = conn.execute("SELECT * FROM fragment_pages WHERE page_id=? AND profile=? AND page_hash=?",
                                 (page["id"], profile, page["content_hash"])).fetchone()
            if ready is None:
                raise ValueError(f"Page {page['id']} is incomplete")
            cursor = 0
            for part in mappings:
                if part["start"] > cursor or part["end"] <= part["start"] or part["end"] > len(page["content_text"]):
                    raise ValueError(f"Page {page['id']} has invalid coverage")
                cursor = max(cursor, part["end"])
                text = page["name"] + "\n\n" + (part["heading"] + "\n\n" if part["heading"] else "") + page["content_text"][part["start"]:part["end"]]
                if server.hash_text(text) != part["input_hash"]:
                    raise ValueError(f"Page {page['id']} has stale fragment input")
                count = len(tokenizer.encode(text, add_special_tokens=False))
                if count > service.embeddings.fragment_limit():
                    raise ValueError(f"Page {page['id']} exceeds token budget")
                vector = service.fragment_index.vector(profile, part["input_hash"])
                server.checked_vector(vector or [], 4096 if service.embeddings.is_qwen() else None)
                max_tokens = max(max_tokens, count)
                total_tokens += count
                chunks += 1
            if cursor != len(page["content_text"]):
                raise ValueError(f"Page {page['id']} has an uncovered tail")
            chars += cursor
    return dict(pages=len(pages), fragments=chunks, covered_chars=chars, coverage=1.0,
                fragment_input_tokens=total_tokens, max_fragment_tokens=max_tokens)


def evaluate(service, queries):
    rows = []
    embed_query = service.embeddings.embed_query
    for case in queries:
        started = time.monotonic()
        vector = embed_query(case["query"])
        service.embeddings.embed_query = lambda text: vector
        original = service.settings
        try:
            service.settings = replace(original, semantic_min_score=-1)
            semantic = service.semantic_results(case["query"], 5, {})
            service.settings = original
            public = service.search_docs(case["query"], None, 5)
        finally:
            service.settings = original
            service.embeddings.embed_query = embed_query
        rows.append(dict(case, semantic=[dict(id=p["id"], score=round(p["semantic_score"], 6),
                         fragment=p.get("fragment")) for p in semantic],
                         public=public["results"], elapsed_seconds=round(time.monotonic() - started, 3)))
    return {"status": service.index_status(), "queries": rows}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--queries", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--reindex", action="store_true")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    service = server.ProductDocsService(server.Settings.from_env())
    started = time.monotonic()
    reindex = service.reindex_docs(force=args.force) if args.reindex else None
    # Keep a failed run's evidence and avoid paid query probes until coverage is complete.
    status = service.index_status()
    complete = status.get("semantic_ready", True)
    report = (evaluate(service, json.loads(Path(args.queries).read_text(encoding="utf-8-sig")))
              if complete else {"status": status, "queries": []})
    report.update(reindex=reindex, elapsed_seconds=round(time.monotonic() - started, 3),
                  cache_bytes=Path(service.settings.cache_path).stat().st_size,
                  coverage_audit=audit_coverage(service) if complete else None)
    Path(args.output).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"output": args.output, "status": report["status"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
