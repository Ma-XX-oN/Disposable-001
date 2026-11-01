import unittest
from issue_1_feature import add_pair


class Smoke(unittest.TestCase):
  def test_issue_1_feature(self):
    self.assertEqual(add_pair(1, 1), 2)

  def test_negative_numbers(self):
    self.assertEqual(add_pair(-4, 2), -2)

  def test_invalid_left_operand(self):
    with self.assertRaises(AssertionError):
      add_pair('1', 1)

  def test_invalid_boolean_operand(self):
    with self.assertRaises(AssertionError):
      add_pair(True, 1)
