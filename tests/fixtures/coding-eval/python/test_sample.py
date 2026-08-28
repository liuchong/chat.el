import unittest

import sample


class SampleTest(unittest.TestCase):
    def test_divide(self):
        self.assertEqual(2.5, sample.divide(5, 2))
        with self.assertRaises(ValueError):
            sample.divide(1, 0)

    def test_label(self):
        self.assertEqual("entry:alpha", sample.label("alpha"))

    def test_normalize(self):
        self.assertEqual("alpha beta", sample.normalize_name("  Alpha   BETA "))

    def test_active(self):
        self.assertTrue(sample.active({"state": "active"}))
        self.assertFalse(sample.active({"state": "paused"}))


if __name__ == "__main__":
    unittest.main()
