"""Tests for the contracts v1 generator and the SQL replay it stands on.

The generator's whole claim is that it reads the migrations the way Postgres does. Most of these
tests are the places where a simpler reading would be wrong: a function replaced with a new
signature, a grant revoked later, an argument list containing a comma inside a type, a dollar
quote nested inside a body, and a guard applied to somebody other than the caller.

Includes the two enum-drift tests that lived in test_check_preview.py until enums.json moved here.
"""

import json
import tempfile
import unittest
from pathlib import Path

import generate_v1
import pgparse


def write(root: Path, relative: str, content: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


class ReplayTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.migrations = self.root / "supabase" / "migrations"
        self.migrations.mkdir(parents=True)

    def tearDown(self):
        self._tmp.cleanup()

    def load(self):
        return pgparse.load(self.migrations)

    def test_drop_then_create_leaves_only_the_new_signature(self):
        write(self.root, "supabase/migrations/1_a.sql",
              "CREATE FUNCTION public.f(p_a text) RETURNS void LANGUAGE sql AS $$ SELECT 1 $$;\n"
              "GRANT EXECUTE ON FUNCTION public.f(text) TO authenticated;\n")
        write(self.root, "supabase/migrations/2_b.sql",
              "DROP FUNCTION public.f(text);\n"
              "CREATE FUNCTION public.f(p_key text, p_a text) RETURNS void LANGUAGE sql AS $$ SELECT 1 $$;\n"
              "GRANT EXECUTE ON FUNCTION public.f(text, text) TO authenticated;\n")
        live = self.load()
        self.assertEqual(sorted(live), ["public.f(text, text)"])

    def test_create_or_replace_keeps_existing_grants(self):
        write(self.root, "supabase/migrations/1_a.sql",
              "CREATE FUNCTION public.f() RETURNS void LANGUAGE sql AS $$ SELECT 1 $$;\n"
              "GRANT EXECUTE ON FUNCTION public.f() TO authenticated;\n")
        write(self.root, "supabase/migrations/2_b.sql",
              "CREATE OR REPLACE FUNCTION public.f() RETURNS void LANGUAGE sql AS $$ SELECT 2 $$;\n")
        self.assertEqual(self.load()["public.f()"].grants, {"authenticated"})

    def test_a_later_revoke_removes_the_grant(self):
        write(self.root, "supabase/migrations/1_a.sql",
              "CREATE FUNCTION public.f() RETURNS void LANGUAGE sql AS $$ SELECT 1 $$;\n"
              "GRANT EXECUTE ON FUNCTION public.f() TO authenticated, anon;\n"
              "REVOKE ALL ON FUNCTION public.f() FROM anon;\n")
        self.assertEqual(self.load()["public.f()"].grants, {"authenticated"})

    def test_revoke_from_public_clears_everything(self):
        write(self.root, "supabase/migrations/1_a.sql",
              "CREATE FUNCTION public.f() RETURNS void LANGUAGE sql AS $$ SELECT 1 $$;\n"
              "GRANT EXECUTE ON FUNCTION public.f() TO authenticated;\n"
              "REVOKE ALL ON FUNCTION public.f() FROM PUBLIC, anon, authenticated;\n")
        self.assertEqual(self.load()["public.f()"].grants, set())

    def test_a_comma_inside_a_type_does_not_split_the_argument_list(self):
        write(self.root, "supabase/migrations/1_a.sql",
              "CREATE FUNCTION public.f(p_a numeric(10, 2), p_b char(2)[]) RETURNS void "
              "LANGUAGE sql AS $$ SELECT 1 $$;\n")
        fn = self.load()["public.f(numeric, character[])"]
        self.assertEqual([a.name for a in fn.args], ["p_a", "p_b"])

    def test_a_semicolon_inside_a_body_does_not_end_the_statement(self):
        write(self.root, "supabase/migrations/1_a.sql",
              "CREATE FUNCTION public.f() RETURNS void LANGUAGE plpgsql AS $$\n"
              "BEGIN\n  PERFORM 1; PERFORM 2;\nEND $$;\n"
              "GRANT EXECUTE ON FUNCTION public.f() TO authenticated;\n")
        self.assertEqual(self.load()["public.f()"].grants, {"authenticated"})

    def test_a_nested_dollar_quote_is_respected(self):
        write(self.root, "supabase/migrations/1_a.sql",
              "CREATE FUNCTION public.f() RETURNS void LANGUAGE plpgsql AS $$\n"
              "BEGIN\n  EXECUTE $q$ SELECT ';' $q$;\nEND $$;\n"
              "GRANT EXECUTE ON FUNCTION public.f() TO authenticated;\n")
        self.assertEqual(self.load()["public.f()"].grants, {"authenticated"})

    def test_a_comment_does_not_hide_a_statement_or_leak_an_apostrophe(self):
        write(self.root, "supabase/migrations/1_a.sql",
              "-- a comment with an apostrophe: don't\n"
              "CREATE FUNCTION public.f() RETURNS void LANGUAGE sql AS $$ SELECT 1 $$;\n")
        self.assertIn("public.f()", self.load())

    def test_defaults_mark_an_argument_optional(self):
        write(self.root, "supabase/migrations/1_a.sql",
              "CREATE FUNCTION public.f(p_a text, p_b integer DEFAULT 20) RETURNS void "
              "LANGUAGE sql AS $$ SELECT 1 $$;\n")
        fn = self.load()["public.f(text, integer)"]
        self.assertEqual([a.optional for a in fn.args], [False, True])


class TableTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        (self.root / "supabase" / "migrations").mkdir(parents=True)

    def tearDown(self):
        self._tmp.cleanup()

    def test_multiple_add_column_clauses_in_one_alter(self):
        write(self.root, "supabase/migrations/1_a.sql",
              "CREATE TABLE public.t (id uuid PRIMARY KEY, a text NOT NULL);\n"
              "ALTER TABLE public.t ADD COLUMN b integer, ADD COLUMN c boolean DEFAULT false;\n")
        t = pgparse.load_tables(self.root / "supabase" / "migrations")["public.t"]
        self.assertEqual([c.name for c in t.columns], ["id", "a", "b", "c"])

    def test_table_constraints_are_not_columns(self):
        write(self.root, "supabase/migrations/1_a.sql",
              "CREATE TABLE public.t (\n  id uuid,\n  a text,\n"
              "  CONSTRAINT t_pk PRIMARY KEY (id),\n  UNIQUE (a),\n  CHECK (a <> '')\n);\n")
        t = pgparse.load_tables(self.root / "supabase" / "migrations")["public.t"]
        self.assertEqual([c.name for c in t.columns], ["id", "a"])

    def test_column_level_grants_are_kept_apart_from_whole_row_grants(self):
        write(self.root, "supabase/migrations/1_a.sql",
              "CREATE TABLE public.t (id uuid, a text, secret text);\n"
              "GRANT SELECT (id, a) ON public.t TO authenticated;\n"
              "GRANT UPDATE (a) ON public.t TO authenticated;\n")
        t = pgparse.load_tables(self.root / "supabase" / "migrations")["public.t"]
        self.assertEqual(t.privileges["SELECT"]["authenticated"], {"id", "a"})
        self.assertEqual(t.privileges["UPDATE"]["authenticated"], {"a"})

    def test_a_partition_is_not_catalogued_as_its_own_table(self):
        write(self.root, "supabase/migrations/1_a.sql",
              "CREATE TABLE public.t (id uuid, at timestamptz) PARTITION BY RANGE (at);\n"
              "CREATE TABLE public.t_2026_01 PARTITION OF public.t "
              "FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');\n")
        tables = pgparse.load_tables(self.root / "supabase" / "migrations")
        self.assertIn("public.t", tables)
        self.assertNotIn("public.t_2026_01", tables)


class RequirementsTest(unittest.TestCase):
    """The inference that decides what a client must be before it may call something."""

    def test_a_guard_on_somebody_else_is_not_a_requirement_on_the_caller(self):
        # This is accept_offer: a customer action whose body checks that the *provider being
        # accepted* is still active.
        body = (
            "DECLARE v_uid uuid := private.require_user();\n"
            "BEGIN PERFORM private.require_active_provider(v_thread.provider_id); END"
        )
        fn = pgparse.Function("public", "accept_offer", [], "void", "plpgsql", True, body, "x.sql")
        self.assertNotIn("active_provider", generate_v1.requirements(fn))

    def test_a_guard_on_the_caller_is_a_requirement(self):
        body = (
            "DECLARE v_uid uuid := private.require_user();\n"
            "BEGIN PERFORM private.require_active_provider(v_uid); END"
        )
        fn = pgparse.Function("public", "create_offer", [], "void", "plpgsql", True, body, "x.sql")
        self.assertTrue(generate_v1.requirements(fn)["active_provider"])

    def test_an_admin_role_check_implies_mfa(self):
        body = "BEGIN IF private.has_admin_role(ARRAY['support_agent']::public.admin_role[]) THEN END IF; END"
        fn = pgparse.Function("public", "q", [], "void", "plpgsql", True, body, "x.sql")
        req = generate_v1.requirements(fn)
        self.assertEqual(req["admin_roles"], ["support_agent"])
        self.assertEqual(req["mfa"], "aal2")

    def test_the_step_up_helper_is_a_requirement_and_an_error(self):
        body = (
            "BEGIN IF NOT private.has_admin_role(ARRAY['finance_officer']::public.admin_role[]) "
            "THEN RAISE EXCEPTION 'ERR_PERMISSION_DENIED'; END IF;\n"
            "PERFORM private.require_recent_mfa(); END"
        )
        fn = pgparse.Function("public", "approve", [], "void", "plpgsql", True, body, "x.sql")
        self.assertEqual(generate_v1.requirements(fn)["recent_mfa"], "totp within 5 minutes")
        self.assertIn("ERR_REAUTH_REQUIRED", generate_v1.describe(fn, {})["errors"])

    def test_a_skeleton_stub_raises_feature_unavailable_and_says_it_is_not_built(self):
        body = (
            "BEGIN PERFORM private.require_user(); "
            "PERFORM private.meet_not_built('meet_pause', jsonb_build_object('p_paused', p_paused));"
            " END"
        )
        fn = pgparse.Function("public", "meet_pause", [], "void", "plpgsql", True, body, "x.sql")
        entry = generate_v1.describe(fn, {})
        self.assertEqual(entry["errors"], ["ERR_FEATURE_UNAVAILABLE"])
        self.assertIs(entry["not_built"], True)
        self.assertTrue(entry["requires"]["authenticated"])

    def test_a_built_function_carries_no_not_built_key(self):
        body = "BEGIN PERFORM private.require_user(); END"
        fn = pgparse.Function("public", "f", [], "void", "plpgsql", True, body, "x.sql")
        self.assertNotIn("not_built", generate_v1.describe(fn, {}))


class EnumTest(unittest.TestCase):
    """Moved from test_check_preview.py when enums.json moved to this generator."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        write(self.root, "supabase/migrations/1_init.sql",
              "CREATE TYPE public.user_mode AS ENUM ('customer', 'provider');\n")

    def tearDown(self):
        self._tmp.cleanup()

    def enums(self):
        return generate_v1.declared_enums(self.root)

    def test_a_new_enum_is_picked_up(self):
        write(self.root, "supabase/migrations/2_more.sql",
              "CREATE TYPE public.urgency AS ENUM ('flexible', 'standard');\n")
        self.assertEqual(self.enums()["urgency"], ["flexible", "standard"])

    def test_a_value_added_to_an_existing_type_is_picked_up(self):
        path = self.root / "supabase/migrations/1_init.sql"
        path.write_text(path.read_text().replace("'provider'", "'provider', 'admin'"), encoding="utf-8")
        self.assertEqual(self.enums()["user_mode"], ["customer", "provider", "admin"])

    def test_order_is_declaration_order_because_the_wire_format_depends_on_it(self):
        self.assertEqual(self.enums()["user_mode"], ["customer", "provider"])


class AlterTypeTest(unittest.TestCase):
    """`ALTER TYPE ... ADD VALUE`, which the generator ignored until Meet v5 M0: notification_kind's
    `call_incoming` and `call_missed` existed in the database for two months and not in enums.json."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        write(self.root, "supabase/migrations/1_init.sql",
              "CREATE TYPE public.user_mode AS ENUM ('customer', 'provider');\n")

    def tearDown(self):
        self._tmp.cleanup()

    def enums(self):
        return generate_v1.declared_enums(self.root)

    def test_an_added_value_goes_at_the_end(self):
        write(self.root, "supabase/migrations/2_add.sql",
              "ALTER TYPE public.user_mode ADD VALUE IF NOT EXISTS 'admin';\n")
        self.assertEqual(self.enums()["user_mode"], ["customer", "provider", "admin"])

    def test_before_and_after_place_the_value_where_postgres_does(self):
        write(self.root, "supabase/migrations/2_add.sql",
              "ALTER TYPE public.user_mode ADD VALUE 'guest' BEFORE 'customer';\n"
              "ALTER TYPE public.user_mode ADD VALUE 'worker' AFTER 'customer';\n"
              "alter type public.user_mode add value if not exists 'admin' after 'provider';\n")
        self.assertEqual(self.enums()["user_mode"], ["guest", "customer", "worker", "provider", "admin"])

    def test_if_not_exists_on_a_present_value_changes_nothing(self):
        write(self.root, "supabase/migrations/2_add.sql",
              "ALTER TYPE public.user_mode ADD VALUE IF NOT EXISTS 'customer' AFTER 'provider';\n")
        self.assertEqual(self.enums()["user_mode"], ["customer", "provider"])

    def test_migrations_replay_in_filename_order_and_statements_in_file_order(self):
        write(self.root, "supabase/migrations/2_add.sql",
              "ALTER TYPE public.user_mode ADD VALUE 'admin';\n"
              "CREATE TYPE public.urgency AS ENUM ('standard');\n"
              "ALTER TYPE public.urgency ADD VALUE 'flexible' BEFORE 'standard';\n")
        write(self.root, "supabase/migrations/3_more.sql",
              "ALTER TYPE public.user_mode ADD VALUE 'worker' BEFORE 'admin';\n")
        enums = self.enums()
        self.assertEqual(enums["user_mode"], ["customer", "provider", "worker", "admin"])
        self.assertEqual(enums["urgency"], ["flexible", "standard"])

    def test_a_commented_out_statement_is_not_replayed(self):
        write(self.root, "supabase/migrations/2_add.sql",
              "-- ALTER TYPE public.user_mode ADD VALUE 'admin';\n")
        self.assertEqual(self.enums()["user_mode"], ["customer", "provider"])

    def test_what_postgres_refuses_is_refused(self):
        cases = {
            "ALTER TYPE public.nope ADD VALUE 'x';": "no migration creates that enum",
            "ALTER TYPE public.user_mode ADD VALUE 'x' AFTER 'nope';": "has no value 'nope'",
            "ALTER TYPE public.user_mode ADD VALUE 'provider';": "without IF NOT EXISTS",
        }
        for statement, message in cases.items():
            with self.subTest(statement=statement):
                write(self.root, "supabase/migrations/2_add.sql", statement + "\n")
                with self.assertRaisesRegex(ValueError, message):
                    self.enums()

    def test_an_added_value_reaches_every_artefact_that_names_the_enum(self):
        write(self.root, "supabase/migrations/2_add.sql",
              "ALTER TYPE public.user_mode ADD VALUE 'admin';\n"
              "CREATE TABLE public.t (id uuid, mode public.user_mode NOT NULL);\n"
              "GRANT SELECT ON public.t TO authenticated;\n")
        tables = generate_v1.build(self.root)["db-types/tables.json"]["tables"]
        mode = next(c for c in tables[0]["columns"] if c["name"] == "mode")
        self.assertEqual(mode["type"]["enum"], ["customer", "provider", "admin"])


class StateMachineCrossCheckTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        machine = {
            "states": [{"name": "agreed"}, {"name": "payment_pending"}, {"name": "paid_held"}],
            "transitions": [{"id": 1, "from": ["agreed"], "to": "payment_pending"}],
        }
        write(self.root, "contracts/v1/state-machines/job.json", json.dumps(machine))
        (self.root / "supabase" / "migrations").mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        self._tmp.cleanup()

    def test_a_declared_transition_passes(self):
        write(self.root, "supabase/migrations/1_a.sql",
              "SELECT private.job_transition(v_id, 'agreed', 'payment_pending', NULL, 'system');\n")
        self.assertEqual(generate_v1.check_state_machine(self.root), [])

    def test_a_transition_only_in_sql_is_reported(self):
        write(self.root, "supabase/migrations/1_a.sql",
              "SELECT private.job_transition(v_id, 'payment_pending', 'paid_held', NULL, 'system');\n")
        findings = generate_v1.check_state_machine(self.root)
        self.assertEqual(len(findings), 1)
        self.assertIn("payment_pending -> paid_held", findings[0])


if __name__ == "__main__":
    unittest.main()
