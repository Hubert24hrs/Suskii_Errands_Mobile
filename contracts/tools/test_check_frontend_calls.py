import json
import tempfile
import unittest
from pathlib import Path

import check_frontend_calls

CATALOGUE = {
    "functions": [
        {"name": "accept_offer", "arguments": [
            {"name": "p_idempotency_key", "optional": False},
            {"name": "p_offer_id", "optional": False}]},
        {"name": "cancel_request", "arguments": [
            {"name": "p_request_id", "optional": False},
            {"name": "p_reason_code", "optional": True}]},
    ],
}
TABLES = {
    "tables": [
        {"name": "public.payments",
         "columns": [{"name": "id"}, {"name": "status"}, {"name": "checkout_url"}],
         "privileges": {"SELECT": {"authenticated": ["id", "status"]}}},
        {"name": "public.provider_profiles",
         "columns": [{"name": "user_id"}, {"name": "bio"}, {"name": "online"}],
         "privileges": {"SELECT": {"authenticated": ["*"]},
                        "UPDATE": {"authenticated": ["bio"]}}},
    ],
}


class CheckFrontendCallsTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.write("contracts/v1/rpc-catalog/index.json", json.dumps(CATALOGUE))
        self.write("contracts/v1/db-types/tables.json", json.dumps(TABLES))

    def tearDown(self):
        self._tmp.cleanup()

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def findings(self):
        checker = check_frontend_calls.Checker(self.root)
        checker.dart()
        checker.typescript()
        return checker.findings

    def dart(self, body):
        self.write("packages/suskii_data/lib/src/supabase/x.dart", body)

    def test_a_correct_call_passes(self):
        self.dart("f() => _gateway.rpc('accept_offer', <String, Object?>{"
                  "'p_idempotency_key': k, 'p_offer_id': o});")
        self.assertEqual(self.findings(), [])

    def test_a_renamed_argument_and_the_missing_one_are_both_reported(self):
        self.dart("f() => _gateway.rpc('accept_offer', <String, Object?>{"
                  "'p_idempotency_key': k, 'p_offerid': o});")
        found = self.findings()
        self.assertTrue(any("'p_offerid' does not exist" in f for f in found), found)
        self.assertTrue(any("required argument 'p_offer_id'" in f for f in found), found)

    def test_a_function_the_contract_does_not_have(self):
        self.dart("f() => _gateway.rpc('no_such_function');")
        self.assertTrue(any("'no_such_function' is not in the contract" in f
                            for f in self.findings()))

    def test_an_ungranted_column_and_a_missing_one(self):
        self.dart("f() => _gateway.selectList('payments', 'id, checkout_url, nope');")
        found = self.findings()
        self.assertTrue(any("payments.checkout_url not granted" in f for f in found), found)
        self.assertTrue(any("payments.nope does not exist" in f for f in found), found)

    def test_an_update_of_a_column_only_select_is_granted_on(self):
        self.dart("f() => _gateway.updateRows('provider_profiles', <String, Object?>{"
                  "'online': true}, column: 'user_id');")
        self.assertTrue(any("UPDATE provider_profiles.online not granted" in f
                            for f in self.findings()))

    def test_a_helper_that_forwards_the_function_name_is_followed(self):
        self.dart("""
Future<JobRequest> _mutate(String function, String jobId, Map<String, Object?> args) async {
  await _gateway.rpc(function, <String, Object?>{'p_request_id': jobId, ...args});
}
f() => _mutate('cancel_request', id, <String, Object?>{'p_reason_code': r});
g() => _mutate('cancel_request', id, <String, Object?>{'p_reason': r});
""")
        found = self.findings()
        self.assertEqual(len(found), 1, found)
        self.assertIn("'p_reason' does not exist", found[0])

    def test_typescript_calls_are_checked_too(self):
        self.write("apps/web-customer/src/lib/supabase/a.ts", """
await this.gateway.rpc('accept_offer', { p_idempotency_key: k });
const r = await supabase.from('payments').select('id, checkout_url');
""")
        found = self.findings()
        self.assertTrue(any("required argument 'p_offer_id'" in f for f in found), found)
        self.assertTrue(any("payments.checkout_url not granted" in f for f in found), found)

    def test_the_web_gateway_column_constant_is_resolved(self):
        self.write("apps/web-customer/src/lib/supabase/b.ts", """
const columns = 'id, checkout_url';
const row = await this.gateway.selectSingle('payments', columns, 'id', id);
""")
        self.assertTrue(any("payments.checkout_url not granted" in f for f in self.findings()))


if __name__ == "__main__":
    unittest.main()
