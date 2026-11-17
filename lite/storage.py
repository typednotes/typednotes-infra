"""One-time, data-preserving split of a legacy Lite vault.

Stop the old combined container first, then run `python3 -m lite.storage` with
LITE_APP_MIGRATOR_URL and LITE_VAULT_MIGRATOR_URL. URLs never enter argv or logs.
The original encrypted rows and history are retained under retired names.
"""
import hashlib
import os
import subprocess
import sys

from images.database import environment

TABLES = ("public.kv_store", "secrets.infra_migrations")


def psql(url: str, sql: str) -> str:
    result = subprocess.run(["psql", "-X", "-w", "-qAt", "-v", "ON_ERROR_STOP=1"],
                            input=sql, env=environment(url), capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError("Vault split SQL failed; source data has been retained")
    return result.stdout.strip()


def fingerprint(url: str, table: str) -> bytes:
    # Stream rather than materialize vault contents; row order and COPY encoding
    # are deterministic, including empty tables. No encrypted rows are logged.
    process = subprocess.Popen(["psql", "-X", "-w", "-qAt", "-v", "ON_ERROR_STOP=1", "-c",
                                ("SET TIME ZONE 'UTC'; SET bytea_output='hex'; "
                                 f"COPY (SELECT row_to_json(t)::text AS row FROM {table} t ORDER BY row_to_json(t)::text COLLATE \"C\") TO STDOUT;")],
                               env=environment(url), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    digest = hashlib.sha256()
    assert process.stdout is not None
    stream = process.stdout
    for chunk in iter(lambda: stream.read(65536), b""):
        digest.update(chunk)
    _, _ = process.communicate()
    if process.returncode:
        raise ValueError("Could not verify copied vault rows; source data has been retained")
    return digest.digest()


def split(source: str, destination: str) -> None:
    if psql(source, "SELECT current_database();") == psql(destination, "SELECT current_database();"):
        raise ValueError("Application and vault must use different logical database names")
    if psql(source, "SELECT to_regclass('public.kv_store') IS NOT NULL AND to_regclass('secrets.infra_migrations') IS NOT NULL;") != "t":
        raise ValueError("Expected the legacy vault table and its Infra migration history")
    if psql(source, "SELECT to_regclass('public.lite_retired_kv_store') IS NOT NULL OR EXISTS (SELECT FROM pg_namespace WHERE nspname='lite_retired_secrets');") != "f":
        raise ValueError("Retired vault data already exists; inspect the previous split before retrying")
    if psql(source, "SELECT count(*) FROM pg_tables WHERE schemaname='secrets';") != "1":
        raise ValueError("Unexpected vault bookkeeping tables; source data has been retained")

    lock = subprocess.Popen(["psql", "-X", "-w", "-qAt", "-v", "ON_ERROR_STOP=1"],
                            env=environment(source), stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert lock.stdin is not None and lock.stdout is not None
        lock.stdin.write("BEGIN; SET lock_timeout='15s'; LOCK TABLE public.kv_store, secrets.infra_migrations IN SHARE MODE; SELECT 'locked';\n")
        lock.stdin.flush()
        if lock.stdout.readline().strip() != "locked":
            raise ValueError("Could not lock the legacy vault; stop its writers before splitting")
        present = psql(destination, "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema');")
        if present == "0":
            dump = subprocess.run(["pg_dump", "--no-owner", "--no-privileges", "--strict-names",
                                   "--table=public.kv_store", "--table=secrets.infra_migrations"],
                                  env=environment(source), capture_output=True, text=True, check=False)
            if dump.returncode:
                raise ValueError("Could not dump the legacy vault; source data has been retained")
            psql(destination, "BEGIN; CREATE SCHEMA IF NOT EXISTS secrets;\n" + dump.stdout + "\nCOMMIT;")
        elif present != "2" or psql(destination, "SELECT to_regclass('public.kv_store') IS NOT NULL AND to_regclass('secrets.infra_migrations') IS NOT NULL;") != "t":
            raise ValueError("Vault destination is not empty or a previous exact copy; refusing to overwrite it")
        for table in TABLES:
            if fingerprint(source, table) != fingerprint(destination, table):
                raise ValueError("Vault destination differs from source; refusing to retire source data")
        # The app/vault are stopped and SHARE locks block concurrent writes
        # during dump and verification. Rename instead of deleting the original.
        _, _ = lock.communicate("ALTER TABLE public.kv_store RENAME TO lite_retired_kv_store;\n"
                                "ALTER SCHEMA secrets RENAME TO lite_retired_secrets; COMMIT;\n")
        if lock.returncode:
            raise ValueError("Could not retire source vault tables; the verified destination copy is available for retry")
    finally:
        if lock.poll() is None:
            lock.communicate("ROLLBACK;\n")


if __name__ == "__main__":
    try:
        source = os.environ.get("LITE_APP_MIGRATOR_URL", "")
        destination = os.environ.get("LITE_VAULT_MIGRATOR_URL", "")
        if not source or not destination:
            raise ValueError("Set LITE_APP_MIGRATOR_URL and LITE_VAULT_MIGRATOR_URL")
        split(source, destination)
        print("Vault and migration history copied and verified; source retained as public.lite_retired_kv_store and lite_retired_secrets")
    except (OSError, ValueError) as error:
        print(f"Vault split: {error}", file=sys.stderr)
        sys.exit(1)
