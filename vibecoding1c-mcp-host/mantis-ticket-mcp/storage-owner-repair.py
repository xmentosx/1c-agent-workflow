"""Build-time, source-bound repair for the qualified dev-ermakov native family.

The installed reader/publication/retirement implementation remains authoritative.
Unknown source bytes fail closed; this is not a replacement vector backend.
"""
import hashlib
from pathlib import Path
import sys

EXPECTED = {
    "mantis_index.py": "9a306b005a853159aed5af7a2f235fa440775e11124df221f4336659b0e91a49",
    "mantis_vectors.py": "ce27a1201680cd2eca2f585438cd98cd6453fa228df64ff92071d7ffc7c413f6",
}


def repair(root):
    root = Path(root)
    original = {}
    for name, expected in EXPECTED.items():
        raw = (root / name).read_bytes()
        if hashlib.sha256(raw).hexdigest() != expected:
            raise ValueError(f"Unqualified Mantis owner source: {name}; preserve current runtime")
        original[name] = raw.decode("utf-8")
    index = original["mantis_index.py"]
    before = 'or status.get("failures", 0) >= 3):'
    after = '''or (status.get("failures", 0) >= 3 and not (
                    status["phase"] == "deferred" and status.get("reason", "").startswith(
                        "Not enough free space for a full Mantis") and
                    __import__("shutil").disk_usage(self.vectors.root).free >=
                    max(status.get("required_bytes", 0),
                        status.get("candidate_peak_bytes", 0) + (2 << 30))))):'''
    if index.count(before) != 1:
        raise ValueError("Mantis retry owner no longer matches the qualified boundary")
    index = index.replace(before, after)
    vectors = original["mantis_vectors.py"]
    before = 'self.state.run("DELETE FROM meta WHERE key=?", (build_key,))'
    after = '''self.state.run("DELETE FROM meta WHERE key=?", (build_key,))
                        # The fully verified ready inventory passed revision/pointer
                        # CAS in this same publication transaction. Older private
                        # copies contain no authoritative payload absent from it.
                        # Drop only unpublished build pins; reader leases and old
                        # object deletion remain with the existing retirement owner.
                        self.state.run("DELETE FROM meta WHERE key GLOB 'vector_build_*' "
                                       "AND value='unpublished'")'''
    if vectors.count(before) != 1:
        raise ValueError("Mantis verified publication no longer matches the qualified boundary")
    vectors = vectors.replace(before, after)
    changed = {"mantis_index.py": index, "mantis_vectors.py": vectors}
    # Parse both before writing either. No runtime state or database is touched.
    for name, text in changed.items():
        compile(text, str(root / name), "exec")
    for name, text in changed.items():
        (root / name).write_text(text, encoding="utf-8")
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in changed}


if __name__ == "__main__":
    import json
    print(json.dumps(repair(sys.argv[1] if len(sys.argv) > 1 else "/app"), sort_keys=True))
