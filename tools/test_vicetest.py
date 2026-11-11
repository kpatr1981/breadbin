import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
from vicetest import command_output  # noqa: E402


class CommandOutput(unittest.TestCase):
    def test_one_row(self):
        lines = ["/home $ hexdump hello.s | grep 0200:",
                 "0200: 6c 64 61 20 23 30 0a 20", "/home $", "", ""]
        self.assertEqual(command_output(lines, "hexdump hello.s | grep 0200:"),
                         ["0200: 6c 64 61 20 23 30 0a 20"])

    def test_wrapped_command(self):
        # 41 columns: the last character wraps onto the next row (#32)
        cmd = "hexdump ring2049.txt | grep 0600:"
        lines = ["/test $ hexdump ring2049.txt | grep 0600", ":",
                 "0600: 72 69 6e 67 20 32 30 34", "/test $", ""]
        self.assertEqual(command_output(lines, cmd), ["0600: 72 69 6e 67 20 32 30 34"])

    def test_wrapped_at_a_space(self):
        # a space in column 40 is lost when rows are right-stripped
        cmd = "echo " + "a" * 30 + " bbbbbb"
        row = "/ $ " + cmd
        lines = [row[:39], row[40:], "a" * 30 + " bbbbbb", "/ $"]
        self.assertEqual(row[39], " ")
        self.assertEqual(command_output(lines, cmd), ["a" * 30 + " bbbbbb"])

    def test_three_rows(self):
        cmd = "echo " + "x" * 80
        row = "/ $ " + cmd
        lines = [row[:40], row[40:80], row[80:], "x" * 40, "x" * 40, "/ $"]
        self.assertEqual(command_output(lines, cmd), ["x" * 40, "x" * 40])

    def test_no_prompt_yet(self):
        self.assertIsNone(command_output(["/ $ ls", "bin"], "ls"))

    def test_not_typed_yet(self):
        self.assertIsNone(command_output(["/ $", ""], "ls"))

    def test_last_run_wins(self):
        lines = ["/ $ ls", "old", "/ $ ls", "new", "/ $"]
        self.assertEqual(command_output(lines, "ls"), ["new"])


if __name__ == "__main__":
    unittest.main()
