-- Field-level encryption (ADR-0018): the seal round-trips, refuses anything altered or moved,
-- survives both kinds of rotation, and is out of every client role's reach.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(22);

CREATE TEMP TABLE sealed (name text PRIMARY KEY, blob bytea);
INSERT INTO sealed VALUES
  ('a', private.seal('access_note', 'Gate code 4471, ring twice', 'request:a')),
  ('a2', private.seal('access_note', 'Gate code 4471, ring twice', 'request:a'));

-- ---------------------------------------------------------------------------
-- The seal
-- ---------------------------------------------------------------------------
SELECT is(private.open('access_note', (SELECT blob FROM sealed WHERE name = 'a'), 'request:a'),
  'Gate code 4471, ring twice', 'a sealed note opens with its class and context');
SELECT is(get_byte((SELECT blob FROM sealed WHERE name = 'a'), 0), 1,
  'the blob starts with the format version');
SELECT is(position(convert_to('4471', 'UTF8') IN (SELECT blob FROM sealed WHERE name = 'a')), 0,
  'the plaintext appears nowhere in the blob');
SELECT isnt((SELECT blob FROM sealed WHERE name = 'a'), (SELECT blob FROM sealed WHERE name = 'a2'),
  'the same note sealed twice gives two different blobs (a fresh IV each time)');
SELECT ok(private.seal('access_note', NULL, 'request:a') IS NULL
          AND private.open('access_note', NULL, 'request:a') IS NULL,
  'NULL seals to NULL and opens to NULL: no note is not an empty note');

-- ---------------------------------------------------------------------------
-- What it refuses
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$SELECT private.open('access_note', (SELECT blob FROM sealed WHERE name = 'a'), 'request:b')$$,
  'P0001', 'ERR_CIPHERTEXT_INVALID',
  'a ciphertext moved to another row does not open there');
SELECT throws_ok(
  $$SELECT private.open('access_note',
      set_byte((SELECT blob FROM sealed WHERE name = 'a'), 30,
               get_byte((SELECT blob FROM sealed WHERE name = 'a'), 30) # 1), 'request:a')$$,
  'P0001', 'ERR_CIPHERTEXT_INVALID', 'one flipped bit is refused');
SELECT throws_ok(
  $$SELECT private.open('access_note',
      substring((SELECT blob FROM sealed WHERE name = 'a') FROM 1 FOR 40), 'request:a')$$,
  'P0001', 'ERR_CIPHERTEXT_INVALID', 'a truncated blob is refused');

SELECT private.create_field_data_key('test_other_class');
SELECT throws_ok(
  $$SELECT private.open('test_other_class', (SELECT blob FROM sealed WHERE name = 'a'), 'request:a')$$,
  'P0001', 'ERR_CIPHERTEXT_INVALID',
  'a blob sealed for one class does not open as another, even at the same key version');
SELECT throws_ok(
  $$SELECT private.seal('acess_note', 'typo', 'request:a')$$,
  'P0001', 'ERR_ENCRYPTION_KEY_UNAVAILABLE',
  'a class with no data key is refused rather than created: a typo is not a new class');

-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------
SELECT is(length(private.field_kek(1)), 32, 'the KEK comes out of Vault as 32 bytes');
SELECT is((SELECT count(*)::int FROM vault.secrets WHERE name = 'suskii_field_kek_v1'), 1,
  'and lives in Vault under the name private.field_keks records');

SELECT is(private.rotate_field_kek(), 2, 'rotating the KEK makes version 2');
SELECT is((SELECT array_agg(DISTINCT kek_version) FROM private.field_data_keys), ARRAY[2],
  'every data key is re-wrapped under the new KEK');
SELECT is((SELECT count(*)::int FROM private.field_keks WHERE retired_at IS NULL), 1,
  'and exactly one KEK is current');
SELECT is(private.open('access_note', (SELECT blob FROM sealed WHERE name = 'a'), 'request:a'),
  'Gate code 4471, ring twice',
  'a note sealed before the KEK rotation still opens: rotation re-wraps keys, not rows');

SELECT is(private.create_field_data_key('access_note'), 2, 'a new data-key version for the class');
SELECT is(get_byte(private.seal('access_note', 'new', 'request:c'), 4), 2,
  'new seals use it');
SELECT is(private.open('access_note', (SELECT blob FROM sealed WHERE name = 'a'), 'request:a'),
  'Gate code 4471, ring twice', 'and blobs sealed under version 1 still open');

UPDATE private.field_keks SET secret_name = 'missing_kek' WHERE version = 2;
SELECT throws_ok($$SELECT private.seal('access_note', 'x', 'request:d')$$,
  'P0001', 'ERR_ENCRYPTION_KEY_UNAVAILABLE',
  'a KEK missing from Vault fails closed, and says which kind of failure it is');

-- ---------------------------------------------------------------------------
-- Reach
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT array_agg(r || ':' || f ORDER BY r, f)
   FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) r,
        unnest(ARRAY['private.seal(text,text,text)', 'private.open(text,bytea,text)',
                     'private.field_kek(integer)', 'private.field_data_key(text,integer)',
                     'private.rotate_field_kek()', 'private.create_field_data_key(text)']) f
   WHERE has_function_privilege(r, f, 'EXECUTE')),
  NULL, 'no client role, and not service_role, can seal, open or touch a key');
SELECT is(
  (SELECT array_agg(r || ':' || t ORDER BY r, t)
   FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) r,
        unnest(ARRAY['private.field_keks', 'private.field_data_keys']) t
   WHERE has_table_privilege(r, t, 'SELECT')),
  NULL, 'and none can read the key tables');

SELECT * FROM finish();
ROLLBACK;
