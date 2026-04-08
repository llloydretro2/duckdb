#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD_DIR=${BUILD_DIR:-"${ROOT_DIR}/build/release"}
DUCKDB_BIN=${DUCKDB_BIN:-"${BUILD_DIR}/duckdb"}
NINJA_BIN=${NINJA_BIN:-ninja}
HARNESS_SCRIPT=${HARNESS_SCRIPT:-"${ROOT_DIR}/test/bash/test_cuckoo_join_backend.sh"}
BENCH_SCRIPT=${BENCH_SCRIPT:-"${ROOT_DIR}/test/bash/bench_hash_backend.sh"}

if [[ ! -x "${DUCKDB_BIN}" ]]; then
  echo "error: DuckDB binary not found at '${DUCKDB_BIN}'. Build DuckDB first or override DUCKDB_BIN." >&2
  exit 1
fi

if [[ ! -d "${BUILD_DIR}" ]]; then
  echo "error: build directory '${BUILD_DIR}' does not exist. Configure the project first." >&2
  exit 1
fi

WORK_DIR=$(mktemp -d -t cuckoo-phase3-suite-XXXXXX)
cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

DB_PATH="${WORK_DIR}/suite.duckdb"

log() {
echo "[Phase4/Suite] $*"
}

scalar_query() {
  local setup="$1"
  local query="$2"
  query="${query%;}"
  local outfile
  outfile=$(mktemp "${WORK_DIR}/scalar-XXXXXX")
  "${DUCKDB_BIN}" "${DB_PATH}" <<SQL >/dev/null
${setup}
COPY (
${query}
) TO '${outfile}' (FORMAT CSV, HEADER FALSE);
SQL
  local value
  value=$(tr -d '\r' <"${outfile}" | tail -n 1)
  rm -f "${outfile}"
  echo "${value}"
}

sql_expect_error() {
  local sql="$1"
  local expected="$2"
  local err_file
  err_file=$(mktemp "${WORK_DIR}/err-XXXXXX")
  local status
  set +e
  "${DUCKDB_BIN}" "${DB_PATH}" <<SQL >/dev/null 2>"${err_file}"
${sql}
SQL
  status=$?
  set -e
  if [[ ${status} -eq 0 ]]; then
    echo "error: statement unexpectedly succeeded: ${sql}" >&2
    rm -f "${err_file}"
    exit 1
  fi
  if ! grep -q "${expected}" "${err_file}"; then
    echo "error: expected error message containing '${expected}', got:" >&2
    cat "${err_file}" >&2
    rm -f "${err_file}"
    exit 1
  fi
  rm -f "${err_file}"
}

compare_backends() {
  local label="$1"
  local sql="$2"
  local linear
  linear=$(scalar_query "SET hash_join_backend='linear';" "${sql}")
  local cuckoo
  cuckoo=$(scalar_query "SET hash_join_backend='cuckoo';" "${sql}")
  if [[ "${linear}" != "${cuckoo}" ]]; then
    echo "error: ${label} mismatch between backends" >&2
    echo "linear: ${linear}" >&2
    echo "cuckoo: ${cuckoo}" >&2
    exit 1
  fi
}

log "1/6 Running C++ unit tests"
"${NINJA_BIN}" -C "${BUILD_DIR}" test/unittest

log "2/6 SQL smoke tests (linear vs cuckoo, NULLs, residual predicates)"

linear_count=$(scalar_query "SET hash_join_backend='linear';" "SELECT COUNT(*) FROM (VALUES (1),(2)) a(i) JOIN (VALUES (1),(3)) b(i) USING (i);")
if [[ "${linear_count}" != "1" ]]; then
  echo "error: linear backend expected count 1, saw '${linear_count}'" >&2
  exit 1
fi

null_count=$(scalar_query "SET hash_join_backend='linear';" "SELECT COUNT(*) FROM (VALUES (1),(NULL)) a(i) JOIN (VALUES (1),(NULL)) b(i) USING (i);")
if [[ "${null_count}" != "1" ]]; then
  echo "error: NULL handling mismatch, expected 1 got '${null_count}'" >&2
  exit 1
fi

linear_residual=$(scalar_query "SET hash_join_backend='linear';" "SELECT COUNT(*) FROM (VALUES (1,10),(1,5)) a(i,v) JOIN (VALUES (1,9),(1,4)) b(i,v) ON a.i=b.i AND a.v>b.v;")
if [[ "${linear_residual}" != "3" ]]; then
  echo "error: linear residual predicate count expected 3, got '${linear_residual}'" >&2
  exit 1
fi

cuckoo_count=$(scalar_query "SET hash_join_backend='cuckoo';" "SELECT COUNT(*) FROM (VALUES (1),(2)) a(i) JOIN (VALUES (1),(2)) b(i) USING (i);")
if [[ "${cuckoo_count}" != "2" ]]; then
  echo "error: cuckoo backend join expected 2, got '${cuckoo_count}'" >&2
  exit 1
fi

cuckoo_residual=$(scalar_query "SET hash_join_backend='cuckoo';" "SELECT COUNT(*) FROM (VALUES (1,10),(1,5)) a(i,v) JOIN (VALUES (1,9),(1,4)) b(i,v) ON a.i=b.i AND a.v>b.v;")
if [[ "${cuckoo_residual}" != "3" ]]; then
  echo "error: cuckoo residual predicate count expected 3, got '${cuckoo_residual}'" >&2
  exit 1
fi

sql_expect_error "SET hash_join_backend='definitely_invalid_backend';" "Invalid hash_join_backend value"

profile_file="${WORK_DIR}/cuckoo_profile.txt"
log "Saving EXPLAIN ANALYZE profile to ${profile_file}"
"${DUCKDB_BIN}" "${DB_PATH}" <<'SQL' >"${profile_file}"
SET hash_join_backend='cuckoo';
EXPLAIN ANALYZE SELECT * FROM (
  SELECT * FROM range(0, 1024) a(i)
) a
JOIN (
  SELECT * FROM range(0, 1024) b(i)
) b USING (i);
SQL

log "3/6 Cross-backend join-type equivalence (LEFT/RIGHT/FULL/SEMI/ANTI/MARK/SINGLE)"
compare_backends "LEFT JOIN" "SELECT string_agg(concat(coalesce(a.i::VARCHAR, 'NULL'), ':', coalesce(b.i::VARCHAR, 'NULL')), ',' ORDER BY coalesce(a.i, -1), coalesce(b.i, -1)) FROM (VALUES (1),(2),(4)) a(i) LEFT JOIN (VALUES (2),(3)) b(i) ON a.i = b.i;"
compare_backends "RIGHT JOIN" "SELECT string_agg(concat(coalesce(a.i::VARCHAR, 'NULL'), ':', coalesce(b.i::VARCHAR, 'NULL')), ',' ORDER BY coalesce(b.i, -1), coalesce(a.i, -1)) FROM (VALUES (2),(NULL)) a(i) RIGHT JOIN (VALUES (NULL),(2),(5)) b(i) ON a.i = b.i;"
compare_backends "FULL JOIN" "SELECT string_agg(concat(coalesce(a.i::VARCHAR, 'NULL'), ':', coalesce(b.i::VARCHAR, 'NULL')), ',' ORDER BY coalesce(a.i, -1), coalesce(b.i, -1)) FROM (VALUES (1),(2),(NULL)) a(i) FULL JOIN (VALUES (2),(3),(NULL)) b(i) ON a.i = b.i;"
compare_backends "SEMI JOIN via EXISTS" "SELECT string_agg(i::VARCHAR, ',' ORDER BY i) FROM (SELECT a.i FROM (VALUES (1),(2),(3)) a(i) WHERE EXISTS (SELECT 1 FROM (VALUES (2),(3)) b(j) WHERE a.i = b.j)) q;"
compare_backends "ANTI JOIN via NOT EXISTS" "SELECT string_agg(i::VARCHAR, ',' ORDER BY i) FROM (SELECT a.i FROM (VALUES (1),(2),(3)) a(i) WHERE NOT EXISTS (SELECT 1 FROM (VALUES (2),(3)) b(j) WHERE a.i = b.j)) q;"
compare_backends "MARK JOIN" "SELECT string_agg(format('%s:%s', i, CASE WHEN marker THEN 'T' ELSE 'F' END), ',' ORDER BY i) FROM (SELECT a.i, EXISTS(SELECT 1 FROM (VALUES (2),(3)) b(j) WHERE a.i = b.j) AS marker FROM (VALUES (1),(2),(3)) a(i)) q;"
compare_backends "SINGLE JOIN (scalar subquery)" "SELECT string_agg(coalesce(res::VARCHAR, 'NULL'), ',' ORDER BY idx) FROM (SELECT row_number() OVER () AS idx, (SELECT v FROM (VALUES (1,10),(2,20)) s(k,v) WHERE s.k = a.i) AS res FROM (VALUES (1),(2),(4)) a(i)) q;"

log "4/6 Running bash harness ${HARNESS_SCRIPT}"
bash "${HARNESS_SCRIPT}"

log "5/6 Microbenchmark comparison via ${BENCH_SCRIPT} (ROW_COUNT=${ROW_COUNT:-500000})"
ROW_COUNT=${ROW_COUNT:-500000} DB_FILE="${WORK_DIR}/bench.duckdb" bash "${BENCH_SCRIPT}"

log "6/6 Sanity check: EXPLAIN output for LINEAR backend"
linear_profile="${WORK_DIR}/linear_profile.txt"
"${DUCKDB_BIN}" "${DB_PATH}" <<'SQL' >"${linear_profile}"
SET hash_join_backend='linear';
EXPLAIN ANALYZE SELECT * FROM (
  SELECT * FROM range(0, 2048) a(i)
) a
JOIN (
  SELECT * FROM range(0, 2048, 2) b(i)
) b USING (i);
SQL

log "Suite complete. Profiles stored in ${profile_file} and ${linear_profile}"
