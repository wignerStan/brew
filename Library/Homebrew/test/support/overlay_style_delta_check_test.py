#!/usr/bin/env python3
import unittest

from overlay_style_delta_check import parse_style_output


class ParseStyleOutputTest(unittest.TestCase):
    def test_nonzero_status_with_known_diagnostic_and_fatal_output_fails_closed(self):
        ranges = {"Library/Homebrew/foo.rb": [(10, 10)]}
        output = (
            "Library/Homebrew/foo.rb:4:1: C: existing offense\n"
            "fatal: parser crashed while inspecting another file\n"
        )

        recognized, changed, fatal = parse_style_output(output, ranges, 2)

        self.assertEqual(len(recognized), 1)
        self.assertFalse(changed)
        self.assertEqual(fatal, ["fatal: parser crashed while inspecting another file"])

    def test_located_changed_diagnostic_is_reported_without_false_fatal_output(self):
        ranges = {"Library/Homebrew/foo.rb": [(10, 10)]}
        output = "Library/Homebrew/foo.rb:10:1: C: new offense\n1 file inspected\n"

        recognized, changed, fatal = parse_style_output(output, ranges, 1)

        self.assertEqual(recognized, changed)
        self.assertFalse(fatal)


if __name__ == "__main__":
    unittest.main()
