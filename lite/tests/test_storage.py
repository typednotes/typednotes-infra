import json
import os
import pwd
import socket
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import urlencode

from lite.storage import fingerprint, psql, split
from local.postgres import Postgres


@unittest.skipUnless(os.environ.get("LOCAL_POSTGRES_BIN"), "Set LOCAL_POSTGRES_BIN to exercise a real legacy vault split")
class VaultSplitTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        self.pg = Postgres(self.work.name, binaries=os.environ["LOCAL_POSTGRES_BIN"],
                           identity=pwd.getpwuid(os.getuid()), port=port)
        self.pg.start()
        self.addCleanup(self.pg.stop)
        self.pg.psql("CREATE DATABASE vault;")
        user = self.pg.identity.pw_name
        query = urlencode({"host": str(self.pg.socket), "port": port})
        self.source = f"postgresql://{user}@/postgres?{query}"
        self.destination = f"postgresql://{user}@/vault?{query}"
        self.path = patch.dict(os.environ, {"PATH": os.environ["LOCAL_POSTGRES_BIN"] + ":" + os.environ["PATH"]})
        self.path.start()
        self.addCleanup(self.path.stop)
        psql(self.source, "CREATE TABLE app_fixture(value text); INSERT INTO app_fixture VALUES ('keep');"
             "CREATE TABLE kv_store(key text PRIMARY KEY, value bytea);"
             "INSERT INTO kv_store VALUES ('vault/key', decode('001122ff', 'hex'));"
             "CREATE SCHEMA secrets; CREATE TABLE secrets.infra_migrations(id text PRIMARY KEY, sql text, applied_at timestamptz DEFAULT now());"
             "INSERT INTO secrets.infra_migrations(id, sql) VALUES ('0001', 'CREATE TABLE kv_store(...);');")

    def test_copy_preserves_ciphertext_history_and_original_rows(self):
        expected = [fingerprint(self.source, table) for table in ("public.kv_store", "secrets.infra_migrations")]
        split(self.source, self.destination)
        self.assertEqual([fingerprint(self.destination, table) for table in ("public.kv_store", "secrets.infra_migrations")], expected)
        self.assertEqual(psql(self.source, "SELECT value FROM app_fixture;"), "keep")
        self.assertEqual(psql(self.source, "SELECT to_regclass('public.kv_store') IS NULL;"), "t")
        self.assertEqual(psql(self.source, "SELECT encode(value, 'hex') FROM lite_retired_kv_store;"), "001122ff")
        self.assertEqual(psql(self.source, "SELECT id FROM lite_retired_secrets.infra_migrations;"), "0001")

    def test_unrelated_destination_and_same_database_are_never_overwritten(self):
        with self.assertRaisesRegex(ValueError, "different logical"):
            split(self.source, self.source)
        psql(self.destination, "CREATE TABLE unrelated(value text); INSERT INTO unrelated VALUES ('keep');")
        with self.assertRaisesRegex(ValueError, "refusing to overwrite"):
            split(self.source, self.destination)
        self.assertEqual(psql(self.destination, "SELECT value FROM unrelated;"), "keep")
        self.assertEqual(psql(self.source, "SELECT count(*) FROM kv_store;"), "1")

    def test_verified_copy_can_resume_after_interruption_but_drift_cannot(self):
        # Simulate an interruption after restore but before source retirement.
        from lite import storage
        real_fingerprint = storage.fingerprint
        with patch.object(storage, "fingerprint", side_effect=ValueError("interrupted")), self.assertRaisesRegex(ValueError, "interrupted"):
            split(self.source, self.destination)
        self.assertEqual(psql(self.source, "SELECT count(*) FROM kv_store;"), "1")
        self.assertEqual(real_fingerprint(self.source, "public.kv_store"), real_fingerprint(self.destination, "public.kv_store"))
        psql(self.destination, "UPDATE kv_store SET value=decode('ff', 'hex');")
        with self.assertRaisesRegex(ValueError, "differs from source"):
            split(self.source, self.destination)
        psql(self.destination, "UPDATE kv_store SET value=decode('001122ff', 'hex');")
        split(self.source, self.destination)
        self.assertEqual(psql(self.source, "SELECT to_regclass('public.kv_store') IS NULL;"), "t")

    @unittest.skipUnless(os.environ.get("LOCAL_RELEASE_BUNDLE"), "Set LOCAL_RELEASE_BUNDLE to check resolved service SQL on split storage")
    def test_resolved_service_sql_applies_to_split_databases(self):
        from images import migrations
        root = Path(os.environ["LOCAL_RELEASE_BUNDLE"])
        manifest = json.loads((root / "manifest.json").read_text())
        self.pg.psql("CREATE DATABASE release_app;")
        self.pg.psql("CREATE DATABASE release_vault;")
        for database, schemas in (("release_app", ("core", "ledger", "liaison")), ("release_vault", ("secrets",))):
            sql = lambda text, database=database: self.pg.psql(text, database=database)
            migrations.apply(sql, manifest, root, schemas=schemas)
            migrations.apply(sql, manifest, root, schemas=schemas)
            self.assertEqual(sql("SELECT to_regclass('public.kv_store') IS NOT NULL;"), "t\n" if database == "release_vault" else "f\n")
