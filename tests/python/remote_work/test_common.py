from pathlib import Path
import json
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
RUNTIME = REPO / ".agents/skills/itl-remote-runner/scripts"
sys.path.insert(0, str(RUNTIME))

from itl_remote import common


class CommonIoTests(unittest.TestCase):
    def test_read_json_retries_transient_windows_access_lock(self):
        error = PermissionError(13, "scanner lock")
        with mock.patch.object(common.os, "name", "nt"), \
             mock.patch.object(common.Path, "read_text", side_effect=[error, '{"ok": 1}']) as read, \
             mock.patch.object(common.time, "sleep") as sleep:
            self.assertEqual({"ok": 1}, common.read_json("state.json"))
        self.assertEqual(2, read.call_count)
        sleep.assert_called_once()

    def test_read_json_does_not_retry_content_errors(self):
        with mock.patch.object(common.Path, "read_text", return_value="{broken") as read, \
             mock.patch.object(common.time, "sleep") as sleep:
            with self.assertRaises(json.JSONDecodeError):
                common.read_json("state.json")
        read.assert_called_once()
        sleep.assert_not_called()

    def test_read_json_does_not_retry_missing_file(self):
        with mock.patch.object(common.os, "name", "nt"), \
             mock.patch.object(common.Path, "read_text", side_effect=FileNotFoundError(2, "missing")) as read, \
             mock.patch.object(common.time, "sleep") as sleep:
            with self.assertRaises(FileNotFoundError):
                common.read_json("state.json")
        read.assert_called_once()
        sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()
