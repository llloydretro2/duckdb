#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DUCKDB_BIN=${DUCKDB_BIN:-"${ROOT_DIR}/build/release/duckdb"}
DB_FILE=${DB_FILE:-"${ROOT_DIR}/bench_hash_backend.duckdb"}
ROW_COUNT=${ROW_COUNT:-2000000}

if [[ ! -x "${DUCKDB_BIN}" ]]; then
  echo "error: DuckDB binary not found at '${DUCKDB_BIN}'. Set DUCKDB_BIN to the built duckdb executable." >&2
  exit 1
fi

echo "[bench] preparing ${ROW_COUNT} rows in ${DB_FILE}"
"${DUCKDB_BIN}" "${DB_FILE}" <<SQL >/dev/null
PRAGMA threads=4;
DROP TABLE IF EXISTS build;
DROP TABLE IF EXISTS probe;
CREATE TABLE build AS
SELECT i AS id, i % 4096 AS k, random() AS payload
FROM range(${ROW_COUNT}) t(i);
CREATE TABLE probe AS
SELECT i AS id, i % 4096 AS k
FROM range(${ROW_COUNT}) t(i);
CHECKPOINT;
SQL

run_query() {
  local backend="$1"
  echo "[bench] backend=${backend}"
  /usr/bin/time -p "${DUCKDB_BIN}" "${DB_FILE}" <<SQL >/dev/null
PRAGMA threads=4;
SET hash_join_backend='${backend}';
SELECT COUNT(*) FROM probe p JOIN build b USING (k);
SQL
  echo
}

run_query "linear"
run_query "cuckoo"
