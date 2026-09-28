"""Cold index snapshot, invoked only by the host cutover owner in an isolated container.

No credentials or server code are loaded. Restore validates the entire archive
before changing the mounted index. A failed restore retains the archive for retry.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def validate_members(members):
    seen = set()
    links = {}
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not path.parts:
            raise ValueError("Snapshot has an unsafe member path")
        name = str(path)
        if name in seen:
            raise ValueError("Snapshot has duplicate member paths")
        seen.add(name)
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise ValueError("Snapshot contains a non-file index entry")
        if member.issym() or member.islnk():
            target = PurePosixPath(member.linkname)
            if target.is_absolute() or not target.parts or (member.islnk() and ".." in target.parts):
                raise ValueError("Snapshot link escapes the index")
            links[path] = member

    def resolve(parts, visiting):
        # Hugging Face snapshots use ../../blobs links, including link chains.
        # Resolve each component through archive links before processing '..':
        # lexical normalization alone misses escapes through a linked directory.
        current = []
        for part in parts:
            if part == "..":
                if len(current) <= 1:
                    raise ValueError("Snapshot link escapes the index")
                current.pop()
                continue
            current.append(part)
            if current[0] != "index":
                raise ValueError("Snapshot link escapes the index")
            path = PurePosixPath(*current)
            link = links.get(path)
            if link is not None:
                if path in visiting:
                    raise ValueError("Snapshot contains a link cycle")
                target = PurePosixPath(link.linkname).parts
                if link.issym():
                    target = tuple(current[:-1]) + target
                current = resolve(target, visiting | {path})
        return current

    for member in members:
        path = PurePosixPath(member.name)
        if any(parent in links for parent in path.parents):
            raise ValueError("Snapshot writes through a link")
        if path in links:
            resolve(path.parts, set())
        if member.islnk() and str(PurePosixPath(member.linkname)) not in seen:
            raise ValueError("Snapshot hard link has no member target")


def snapshot(data, archive):
    if archive.exists():
        raise ValueError("Snapshot already exists; preserve it and select a new operation")
    if not any(data.iterdir()):
        raise ValueError("Retained index is empty")
    partial = archive.with_suffix(".partial")
    if partial.exists():
        raise ValueError("Partial snapshot already exists")
    with tarfile.open(partial, "w", dereference=False) as output:
        output.add(data, arcname="index", recursive=True)
    with tarfile.open(partial, "r") as source:
        members = source.getmembers()
        validate_members(members)
    partial.rename(archive)
    return {"sha256": digest(archive), "bytes": archive.stat().st_size,
            "members": len(members)}


def restore(data, archive, expected_sha256):
    if not expected_sha256 or digest(archive) != expected_sha256:
        raise ValueError("Snapshot SHA256 differs; index was not modified")
    with tarfile.open(archive, "r") as source:
        members = source.getmembers()
        validate_members(members)
        if not members or any(PurePosixPath(m.name).parts[0] != "index" for m in members):
            raise ValueError("Snapshot does not contain exactly the index root")
        if any(m.islnk() and PurePosixPath(m.linkname).parts[0] != "index" for m in members):
            raise ValueError("Snapshot hard link is outside the index root")
        root = members[0]
        if root.name != "index" or not root.isdir():
            raise ValueError("Snapshot root is not the index directory")
        # The caller mounts one verified owned index at this path. Do not follow
        # existing symlinks while removing a candidate's changed contents.
        for child in data.iterdir():
            if child.is_symlink() or not child.is_dir():
                child.unlink()
            else:
                shutil.rmtree(child)
        contents = []
        for member in members:
            if member.name == "index":
                continue
            member.name = str(PurePosixPath(member.name).relative_to("index"))
            if member.islnk():
                member.linkname = str(PurePosixPath(member.linkname).relative_to("index"))
            contents.append(member)
        # Already validated; preserve directory attributes and Neo4j ownership.
        options = {"filter": "fully_trusted"} if hasattr(tarfile, "data_filter") else {}
        source.extractall(path=data, members=contents, numeric_owner=True, **options)
        os.chmod(data, root.mode)
        if hasattr(os, "chown"):
            os.chown(data, root.uid, root.gid)
        os.utime(data, (root.mtime, root.mtime))
    return {"restored": True, "sha256": expected_sha256, "members": len(members)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("save", "restore"))
    parser.add_argument("--sha256", default="")
    args = parser.parse_args()
    index = Path("/index")
    archive = Path("/snapshot/index.tar")
    if not index.is_mount() or not Path("/snapshot").is_mount():
        raise ValueError("Snapshot helper requires dedicated index and snapshot mounts")
    result = snapshot(index, archive) if args.operation == "save" else restore(index, archive, args.sha256)
    print(json.dumps(result, ensure_ascii=True))
