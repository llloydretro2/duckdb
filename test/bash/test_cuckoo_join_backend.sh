#!/usr/bin/env bash
set -euo pipefail

DUCKDB_BIN=${DUCKDB_BIN:-"./build/release/duckdb"}
DB_PATH=${DB_PATH:-""}

if [[ ! -x "${DUCKDB_BIN}" ]]; then
  echo "error: DuckDB binary not found at '${DUCKDB_BIN}'. Set DUCKDB_BIN to the built duckdb executable." >&2
  exit 1
fi

SCRATCH_DIR=$(mktemp -d -t cuckoo-join-phase3-XXXXXX)
cleanup() {
  rm -rf "${SCRATCH_DIR}"
}
trap cleanup EXIT

if [[ -z "${DB_PATH}" ]]; then
  DB_PATH="${SCRATCH_DIR}/cuckoo_phase3.duckdb"
fi

scalar_query() {
  local setup="$1"
  local query="$2"
  query="${query%;}"
  local outfile
  outfile=$(mktemp "${SCRATCH_DIR}/scalar-XXXXXX")
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
  err_file=$(mktemp "${SCRATCH_DIR}/err-XXXXXX")
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

echo "[Phase3/Bash] Ensuring baseline backend is LINEAR"
default_backend=$(scalar_query "SET hash_join_backend='linear';" "SELECT current_setting('hash_join_backend');")
if [[ "${default_backend}" != "LINEAR" ]]; then
  echo "error: expected default backend to be LINEAR, got '${default_backend}'" >&2
  exit 1
fi

echo "[Phase3/Bash] Verifying linear backend executes joins correctly"
result=$(scalar_query "SET hash_join_backend='linear';" "SELECT COUNT(*) FROM (VALUES (1),(2)) t1(i) JOIN (VALUES (1),(3)) t2(i) USING(i);")
if [[ "${result}" != "1" ]]; then
  echo "error: expected linear backend join count 1, got '${result}'" >&2
  exit 1
fi

echo "[Phase3/Bash] Checking duckdb_settings() reflects LINEAR backend"
settings_value=$(scalar_query "SET hash_join_backend='linear';" "SELECT value FROM duckdb_settings() WHERE name='hash_join_backend';")
if [[ "${settings_value}" != "LINEAR" ]]; then
  echo "error: duckdb_settings() reported '${settings_value}'" >&2
  exit 1
fi

echo "[Phase3/Bash] Linear backend handles duplicate keys"
linear_multiset=$(scalar_query "SET hash_join_backend='linear';" "SELECT list_sort(list(i)) FROM (SELECT i FROM (VALUES (1),(1),(2)) a(i) JOIN (VALUES (1),(1),(2)) b(i) USING(i)) t;")
if [[ "$(echo "${linear_multiset}" | tr -d ' \"')" != "[1,1,1,1,2]" ]]; then
  echo "error: duplicate handling unexpected result '${linear_multiset}'" >&2
  exit 1
fi

echo "[Phase3/Bash] Rejecting unknown backend option"
sql_expect_error "SET hash_join_backend='unknown_backend';" "Invalid hash_join_backend value"

echo "[Phase3/Bash] Switching to cuckoo backend"
cuckoo_backend=$(scalar_query "SET hash_join_backend='cuckoo';" "SELECT current_setting('hash_join_backend');")
if [[ "${cuckoo_backend}" != "CUCKOO" ]]; then
  echo "error: failed to switch to cuckoo backend, got '${cuckoo_backend}'" >&2
  exit 1
fi

echo "[Phase3/Bash] duckdb_settings() reflects CUCKOO backend"
cuckoo_settings=$(scalar_query "SET hash_join_backend='cuckoo';" "SELECT value FROM duckdb_settings() WHERE name='hash_join_backend';")
if [[ "${cuckoo_settings}" != "CUCKOO" ]]; then
  echo "error: duckdb_settings() reported '${cuckoo_settings}' instead of CUCKOO" >&2
  exit 1
fi

echo "[Phase3/Bash] Exercising cuckoo backend join"
join_count=$(scalar_query "SET hash_join_backend='cuckoo';" "SELECT COUNT(*) FROM (VALUES (1),(2)) a(i) JOIN (VALUES (1),(2)) b(i) USING(i);")
if [[ "${join_count}" != "2" ]]; then
  echo "error: cuckoo backend join returned unexpected count '${join_count}'" >&2
  exit 1
fi

echo "[Phase3/Bash] Cuckoo backend handles duplicate keys"
cuckoo_multiset=$(scalar_query "SET hash_join_backend='cuckoo';" "SELECT list_sort(list(i)) FROM (SELECT i FROM (VALUES (1),(1),(2)) a(i) JOIN (VALUES (1),(1),(2)) b(i) USING(i)) t;")
if [[ "$(echo "${cuckoo_multiset}" | tr -d ' \"')" != "[1,1,1,1,2]" ]]; then
  echo "error: cuckoo duplicate handling unexpected result '${cuckoo_multiset}'" >&2
  exit 1
fi

echo "[Phase3/Bash] Cuckoo backend yields zero matches when expected"
zero_count=$(scalar_query "SET hash_join_backend='cuckoo';" "SELECT COUNT(*) FROM (VALUES (1),(2)) a(i) JOIN (VALUES (3),(4)) b(i) USING(i);")
if [[ "${zero_count}" != "0" ]]; then
  echo "error: expected zero matches for disjoint inputs, got '${zero_count}'" >&2
  exit 1
fi

echo "[Phase3/Bash] Resetting backend to LINEAR"
scalar_query "SET hash_join_backend='linear';" "SELECT 1;" >/dev/null

echo "[Phase3/Bash] duckdb_settings() row matches after reset"
reset_value=$(scalar_query "SELECT 1;" "SELECT value FROM duckdb_settings() WHERE name='hash_join_backend';")
if [[ "${reset_value}" != "LINEAR" ]]; then
  echo "error: expected LINEAR after reset but saw '${reset_value}'" >&2
  exit 1
fi

echo "[Phase3/Bash] All checks passed"
