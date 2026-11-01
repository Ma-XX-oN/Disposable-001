import unittest
from issue_1_feature import add_pair


class Integration(unittest.TestCase):
  def test_chained_feature(self):
    self.assertEqual(add_pair(add_pair(2, 3), -1), 4)

  def test_reject_noninteger_result_input(self):
    with self.assertRaises(AssertionError):
      add_pair(None, 5)
