import unittest

from journey import add, setting


class JourneyTest(unittest.TestCase):
    def test_adds_numbers(self):
        self.assertEqual(add(2, 3), 5)

    def test_rejects_non_numbers(self):
        with self.assertRaises(TypeError):
            add("2", 3)

    def test_reads_settings_with_a_dependency(self):
        self.assertEqual(setting("[tool]\nname = journey\n", "tool", "name"), "journey")


if __name__ == "__main__":
    unittest.main()
