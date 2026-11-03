import unittest


class DeclaredRed(unittest.TestCase):
  def test_known_behavioral_gap(self):
    self.assertEqual(1, 2, "RWF788_EXPECTED_FAIL")
