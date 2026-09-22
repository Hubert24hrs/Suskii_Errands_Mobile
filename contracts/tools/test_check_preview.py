import json
import tempfile
import unittest
from pathlib import Path

import check_preview

# The two enum-drift tests that used to live here moved to test_generate_v1.py
# when enums.json moved to generate_v1.py.


def write(root: Path, relative: str, content: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


MIGRATION = """
-- comment mentioning ERR_NOT_A_REAL_CODE_IN_A_COMMENT is still source text
CREATE TYPE public.user_mode AS ENUM ('customer', 'provider');
CREATE FUNCTION public.f() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'ERR_PROVIDER_NOT_VERIFIED' USING ERRCODE = 'P0001';
END $$;
"""


class CheckPreviewTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        write(self.root, "supabase/migrations/1_init.sql", MIGRATION.replace(
            "-- comment mentioning ERR_NOT_A_REAL_CODE_IN_A_COMMENT is still source text\n", ""))
        write(self.root, "supabase/functions/fn/handler.ts", 'return errorResponse(500, "ERR_INTERNAL");\n')
        write(self.root, "supabase/functions/fn/handler_test.ts", 'assert("ERR_ONLY_IN_TESTS");\n')
        self.catalogue([
            {"code": "ERR_PROVIDER_NOT_VERIFIED", "status": "implemented"},
            {"code": "ERR_INTERNAL", "status": "implemented"},
            {"code": "ERR_OFFER_EXPIRED", "status": "planned"},
            {"code": "ERR_NETWORK", "status": "client"},
        ])

    def tearDown(self):
        self._tmp.cleanup()

    def catalogue(self, codes):
        write(self.root, "contracts/v1/error-codes/codes.json", json.dumps({"codes": codes}))

    def errors(self):
        return [f.message for f in check_preview.check(self.root) if f.level == "error"]

    def test_consistent_repository_passes(self):
        self.assertEqual(self.errors(), [])

    def test_a_new_backend_code_must_be_catalogued(self):
        write(self.root, "supabase/functions/fn/other.ts", 'errorResponse(400, "ERR_BRAND_NEW");\n')
        self.assertEqual(self.errors(), ["ERR_BRAND_NEW is raised but missing from error-codes.json"])

    def test_a_raised_code_marked_planned_must_become_implemented(self):
        write(self.root, "supabase/functions/fn/other.ts", 'errorResponse(400, "ERR_OFFER_EXPIRED");\n')
        self.assertIn("ERR_OFFER_EXPIRED is raised but marked planned; mark it implemented", self.errors())

    def test_an_implemented_code_nobody_raises_is_stale(self):
        (self.root / "supabase/functions/fn/handler.ts").write_text("return ok;\n", encoding="utf-8")
        self.assertEqual(self.errors(), ["ERR_INTERNAL is marked implemented but no backend code raises it"])

    def test_codes_only_in_tests_do_not_count(self):
        self.assertNotIn("ERR_ONLY_IN_TESTS", " ".join(self.errors()))



    def test_malformed_and_duplicate_catalogue_entries(self):
        self.catalogue([
            {"code": "ERR_PROVIDER_NOT_VERIFIED", "status": "implemented"},
            {"code": "ERR_INTERNAL", "status": "implemented"},
            {"code": "ERR_INTERNAL", "status": "implemented"},
            {"code": "err_lower", "status": "maybe"},
        ])
        errors = self.errors()
        self.assertIn("duplicate code ERR_INTERNAL", errors)
        self.assertIn("malformed code name 'err_lower'", errors)
        self.assertIn("err_lower: unknown status 'maybe'", errors)

    def test_unknown_app_codes_are_warnings_not_errors(self):
        write(self.root, "packages/suskii_core/lib/src/errors.dart",
              "static const String a = 'ERR_NETWORK';\nstatic const String b = 'ERR_APP_ONLY';\n")
        findings = check_preview.check(self.root)
        warnings = [f.message for f in findings if f.level == "warning"]
        self.assertEqual(len(warnings), 1)
        self.assertIn("ERR_APP_ONLY", warnings[0])
        self.assertEqual(self.errors(), [])


if __name__ == "__main__":
    unittest.main()
