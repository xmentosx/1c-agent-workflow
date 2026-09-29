"""Build and switch a Mantis-owned HNSW generation without new embeddings.

Build reads a paused Flat generation and works on its private copy while the
old server still serves reads. Activate/rollback require the server stopped:
State's owner lock and one SQLite transaction provide the cutover boundary.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import sqlite3
from pathlib import Path

import zvec

from mantis_index import HNSW_CANDIDATES, HNSW_EF
from mantis_state import State, is_link


def generation_path(root: Path, generation: str) -> Path:
    if not re.fullmatch(r"[a-f0-9]{32}", generation):
        raise ValueError("Invalid Mantis vector generation")
    root = Path(root).resolve()
    vectors = root / "vectors"
    path = vectors / generation
    if is_link(vectors) or is_link(path):
        raise RuntimeError("Unexpected link in Mantis vector volume")
    return path


def staging_path(root: Path, generation: str) -> Path:
    generation_path(root, generation)
    staging = Path(root).resolve() / "vector-staging"
    if is_link(staging) or is_link(staging / generation):
        raise RuntimeError("Unexpected link in Mantis vector staging")
    return staging / generation


def active_generation(root: Path) -> tuple[str, str]:
    db = sqlite3.connect(f"file:{root / 'mantis.sqlite'}?mode=ro", uri=True)
    try:
        values = dict(db.execute("SELECT key,value FROM meta WHERE key IN ('vector_generation','index_paused')"))
        return values["vector_generation"], values["index_paused"]
    finally:
        db.close()


def is_hnsw(collection) -> bool:
    return isinstance(collection.schema.vectors[0].index_param, zvec.HnswIndexParam)


def count_vectors(collection) -> int:
    with collection.iter_docs() as docs:
        return sum(1 for _ in docs)


def build(root: Path, expected: str, candidate: str) -> dict:
    source = generation_path(root, expected)
    target = staging_path(root, candidate)
    if expected == candidate or not source.is_dir() or target.exists() or generation_path(root, candidate).exists():
        raise RuntimeError("Migration source missing or candidate already exists")
    current, paused = active_generation(root)
    if current != expected or paused != "1":
        raise RuntimeError("Pause Mantis indexing and verify the active generation before building")
    source_size = sum(p.stat().st_size for p in source.rglob("*") if p.is_file())
    if shutil.disk_usage(source).free < max(8 << 30, source_size * 2):
        raise RuntimeError("Not enough space for the HNSW candidate and recovery headroom")
    target.parent.mkdir(exist_ok=True)
    shutil.copytree(source, target)
    collection = zvec.open(str(target))
    try:
        if is_hnsw(collection):
            raise RuntimeError("Expected a Flat source; candidate is already HNSW")
        before = count_vectors(collection)
        if before == 0:
            raise RuntimeError("Refusing to migrate an empty vector generation")
        collection.create_index("embedding", zvec.HnswIndexParam(
            metric_type=zvec.MetricType.IP, m=16, ef_construction=100,
            quantize_type=zvec.QuantizeType.INT8))
    finally:
        collection.close()
    collection = zvec.open(str(target))
    try:
        after = count_vectors(collection)
        if not is_hnsw(collection) or after != before:
            raise RuntimeError("HNSW candidate failed reopen or vector-count verification")
        with collection.iter_docs() as docs:
            sample = next(iter(docs))
            sample_id = sample.id
            vector = list(sample.vector("embedding"))
        hits = collection.query(zvec.Query(field_name="embedding", vector=vector,
            param=zvec.HnswQueryParam(ef=HNSW_EF)), topk=min(after, HNSW_CANDIDATES))
        if not hits or hits[0].id != sample_id:
            raise RuntimeError("HNSW candidate failed exact-vector sample query")
        return {"source": expected, "candidate": candidate, "vectors": after,
                "bytes": sum(p.stat().st_size for p in target.rglob("*") if p.is_file())}
    finally:
        collection.close()


def switch(root: Path, attachments: Path, expected: str, target: str, rollback=False) -> dict:
    source_path = generation_path(root, expected)
    target_path = generation_path(root, target)
    stage_path = staging_path(root, target)
    if not source_path.is_dir() or (rollback and not target_path.is_dir()) or (
            not rollback and not target_path.is_dir() and not stage_path.is_dir()):
        raise RuntimeError("Expected Mantis vector generation or staged candidate is missing")
    state = State(root, attachments)
    try:
        row = state.one("SELECT value FROM meta WHERE key='vector_generation'")
        paused = state.one("SELECT value FROM meta WHERE key='index_paused'")
        backup = state.one("SELECT value FROM meta WHERE key='vector_rollback_generation'")
        if not row or row["value"] != expected or not paused or paused["value"] != "1":
            raise RuntimeError("Mantis must be stopped at the paused expected generation")
        if rollback:
            if not backup or backup["value"] != target:
                raise RuntimeError("Flat rollback generation is no longer current and recoverable")
        elif backup:
            raise RuntimeError("An earlier vector migration still has a rollback generation")
        if not rollback and not target_path.exists():
            stage_path.rename(target_path)
        collection = zvec.open(str(target_path))
        try:
            if is_hnsw(collection) == rollback:
                raise RuntimeError("Target generation has the wrong vector index type")
            ids = [row["vector_id"] for row in state.all(
                "SELECT vector_id FROM fragments WHERE vector_id<>'' AND vector_version=version")]
            if len(ids) != len(set(ids)):
                raise RuntimeError("Duplicate current Mantis vector IDs")
            for start in range(0, len(ids), 512):
                batch = ids[start:start + 512]
                if len(collection.fetch(batch, include_vector=False)) != len(batch):
                    raise RuntimeError("Target generation is missing current Mantis vectors")
        finally:
            collection.close()
        with state.transaction():
            if state.one("SELECT value FROM meta WHERE key='vector_generation'")["value"] != expected:
                raise RuntimeError("Active vector generation changed during cutover")
            state.run("INSERT OR REPLACE INTO meta VALUES('vector_generation',?)", (target,))
            if rollback:
                state.run("DELETE FROM meta WHERE key='vector_rollback_generation'")
            else:
                state.run("INSERT OR REPLACE INTO meta VALUES('vector_rollback_generation',?)", (expected,))
        return {"active": target, "rollback": None if rollback else expected,
                "verified_current_vectors": len(ids)}
    finally:
        state.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "activate", "rollback"))
    parser.add_argument("--state", type=Path, default=Path("/data/mantis"))
    parser.add_argument("--attachments", type=Path, default=Path("/data/attachments"))
    parser.add_argument("--expected", required=True)
    parser.add_argument("--target", required=True)
    args = parser.parse_args()
    if args.action == "build":
        result = build(args.state, args.expected, args.target)
    else:
        result = switch(args.state, args.attachments, args.expected, args.target,
                        rollback=args.action == "rollback")
    print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
