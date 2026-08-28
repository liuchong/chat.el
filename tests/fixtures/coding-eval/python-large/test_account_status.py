import unittest

from src.account_status import resolve_account_status


class AccountStatusTest(unittest.TestCase):
    def test_missing_account_returns_none(self):
        self.assertIsNone(resolve_account_status([], 7))
