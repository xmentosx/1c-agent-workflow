"""Conservative workflow identity across linked Git worktrees."""
from pathlib import Path
import os

from .common import WorkError, capture


def _resolved(value):
    try:
        return Path(value).resolve()
    except (OSError, TypeError, ValueError):
        return None


def same_path(first, second):
    left, right = _resolved(first), _resolved(second)
    if left is None or right is None:
        return False
    a, b = str(left), str(right)
    return a.casefold() == b.casefold() if os.name == "nt" else a == b


def git_common_dir(project):
    root = _resolved(project)
    if root is None or not root.is_dir():
        return None
    try:
        raw = capture(["git", "-c", "core.quotepath=false", "-C", str(root),
                       "rev-parse", "--git-common-dir"], timeout=10)
        text = raw.decode("utf-8").strip()
    except (WorkError, UnicodeDecodeError, OSError):
        return None
    if not text:
        return None
    path = Path(text)
    if not path.is_absolute():
        path = root / path
    return _resolved(path)


def same_git_workspace(first, second):
    if same_path(first, second):
        return True
    left, right = git_common_dir(first), git_common_dir(second)
    return left is not None and right is not None and same_path(left, right)


def git_main_worktree(project):
    common = git_common_dir(project)
    if common is None or common.name.casefold() != ".git":
        return None
    return common.parent.resolve()
