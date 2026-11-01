import unittest

class Smoke(unittest.TestCase):
  def test_issue_1_feature(self):
    self.assertEqual(1 + 1, 3, 'issue-1 expected failure')
