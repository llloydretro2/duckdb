#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_DIR=${BUILD_DIR:-"${ROOT_DIR}/build/release"}
DUCKDB_BIN=${DUCKDB_BIN:-"${BUILD_DIR}/duckdb"}
NINJA_BIN=${NINJA_BIN:-ninja}
CMAKE_BIN=${CMAKE_BIN:-cmake}

if [[ ! -d "${BUILD_DIR}" ]]; then
  echo "[demo] configuring release build in ${BUILD_DIR}"
  "${CMAKE_BIN}" -S "${ROOT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release
fi

echo "[demo] building DuckDB release binary"
"${NINJA_BIN}" -C "${BUILD_DIR}" duckdb

if [[ ! -x "${DUCKDB_BIN}" ]]; then
  echo "error: expected DuckDB binary at '${DUCKDB_BIN}' after build" >&2
  exit 1
fi

WORK_DIR=$(mktemp -d -t cuckoo-demo-build-XXXXXX)
cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

DB_PATH="${WORK_DIR}/demo.duckdb"
PROFILE_FILE="${WORK_DIR}/cuckoo_profile.txt"

echo
echo "[demo] proving the backend switch exists"
"${DUCKDB_BIN}" "${DB_PATH}" <<'SQL'
SELECT current_setting('hash_join_backend') AS default_backend;
SET hash_join_backend='cuckoo';
SELECT current_setting('hash_join_backend') AS after_switch;
SELECT value AS settings_table_value
FROM duckdb_settings()
WHERE name='hash_join_backend';
SQL

echo
echo "[demo] proving the cuckoo implementation is active via profiling counters"
"${DUCKDB_BIN}" "${DB_PATH}" <<'SQL' >"${PROFILE_FILE}"
PRAGMA enable_profiling=json;
SET hash_join_backend='cuckoo';
EXPLAIN ANALYZE
SELECT COUNT(*)
FROM (
  SELECT i % 64 AS k, i AS payload
  FROM range(0, 4096) t(i)
) build
JOIN (
  SELECT i % 64 AS k
  FROM range(0, 4096) t(i)
) probe
USING (k);
SQL

grep -E '"Cuckoo (Load Factor|Target Load Factor|Kickouts|BFS Failures|Stash Entries|Overflow Entries|Fallback Events)"' "${PROFILE_FILE}" || {
  echo "error: profiling output did not expose cuckoo runtime counters" >&2
  echo "[demo] first 120 lines of profile output:" >&2
  sed -n '1,120p' "${PROFILE_FILE}" >&2
  exit 1
}

echo
echo "[demo] sample join result under the cuckoo backend"
"${DUCKDB_BIN}" "${DB_PATH}" <<'SQL'
SET hash_join_backend='cuckoo';
SELECT COUNT(*)
FROM (VALUES (1),(2),(2),(3)) a(i)
JOIN (VALUES (2),(2),(3),(4)) b(i)
USING (i);
SQL

echo
echo "[demo] success: build completed, backend switch works, and cuckoo-specific counters were emitted"
