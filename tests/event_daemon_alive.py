"""Check /proc liveness when a daemon exits while its status is read."""

import importlib.util
from pathlib import Path
import unittest
from unittest.mock import mock_open, patch


path = Path(__file__).parent / "event_daemon" / "process.py"
spec = importlib.util.spec_from_file_location("event_daemon_process", path)
process = importlib.util.module_from_spec(spec)
spec.loader.exec_module(process)


class AliveTests(unittest.TestCase):
    def test_running_and_zombie(self):
        for state, expected in (("S", True), ("Z", False)):
            with self.subTest(state=state), patch(
                "builtins.open", mock_open(read_data=f"123 (ipmievd) {state} 1 0")
            ) as opened:
                self.assertEqual(process.alive(123), expected)
                opened.assert_called_once_with("/proc/123/stat", encoding="ascii")

    def test_gone_before_open(self):
        with patch("builtins.open", side_effect=FileNotFoundError):
            self.assertFalse(process.alive(123))

    def test_gone_during_read(self):
        handle = mock_open()
        handle.return_value.__enter__.return_value.read.side_effect = ProcessLookupError
        with patch("builtins.open", handle):
            self.assertFalse(process.alive(123))


if __name__ == "__main__":
    unittest.main()
