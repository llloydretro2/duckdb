#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_DIR=${BUILD_DIR:-"${ROOT_DIR}/build/release"}
DUCKDB_BIN=${DUCKDB_BIN:-"${BUILD_DIR}/duckdb"}
JOB_DB_PATH=${JOB_DB_PATH:-"${ROOT_DIR}/data/job/imdb.duckdb"}
QUERY_DIR=${QUERY_DIR:-"${ROOT_DIR}/data/job/job_queries"}
RESULTS_DIR=${RESULTS_DIR:-"${ROOT_DIR}/job_query_benchmark"}
THREADS=${THREADS:-4}
RUN_TIMEOUT=${RUN_TIMEOUT:-600}
SLEEP_BETWEEN=${SLEEP_BETWEEN:-1}
ENABLE_CHECK=${ENABLE_CHECK:-1}
JOB_SCRIPT=${JOB_SCRIPT:-"${ROOT_DIR}/evaluation/job_queries_cuckoo_ab.sh"}

if [[ ! -x "${DUCKDB_BIN}" ]]; then
  echo "error: DuckDB binary not found at '${DUCKDB_BIN}'. Run evaluation/demo_build_and_enable.sh first." >&2
  exit 1
fi

if [[ ! -f "${JOB_DB_PATH}" ]]; then
  echo "error: JOB database not found at '${JOB_DB_PATH}'" >&2
  exit 1
fi

if [[ ! -d "${QUERY_DIR}" ]]; then
  echo "error: JOB query directory not found at '${QUERY_DIR}'" >&2
  exit 1
fi

if [[ ! -x "${JOB_SCRIPT}" ]]; then
  echo "error: JOB benchmark script not found at '${JOB_SCRIPT}'" >&2
  exit 1
fi

if [[ "${ENABLE_CHECK}" == "1" ]]; then
  echo "[demo-job] confirming cuckoo backend switch before full JOB run"
  "${DUCKDB_BIN}" "${JOB_DB_PATH}" <<'SQL'
SELECT current_setting('hash_join_backend') AS default_backend;
SET hash_join_backend='cuckoo';
SELECT current_setting('hash_join_backend') AS after_switch;
SELECT value
FROM duckdb_settings()
WHERE name='hash_join_backend';
SQL
  echo
fi

echo "[demo-job] starting full JOB benchmark"
echo "[demo-job] database     : ${JOB_DB_PATH}"
echo "[demo-job] query dir    : ${QUERY_DIR}"
echo "[demo-job] results dir  : ${RESULTS_DIR}"
echo "[demo-job] threads      : ${THREADS}"
echo "[demo-job] run timeout  : ${RUN_TIMEOUT}"
echo

DUCKDB_BIN="${DUCKDB_BIN}" \
JOB_DB_PATH="${JOB_DB_PATH}" \
QUERY_DIR="${QUERY_DIR}" \
RESULTS_DIR="${RESULTS_DIR}" \
THREADS="${THREADS}" \
RUN_TIMEOUT="${RUN_TIMEOUT}" \
SLEEP_BETWEEN="${SLEEP_BETWEEN}" \
bash "${JOB_SCRIPT}"

echo
echo "[demo-job] benchmark complete"
echo "[demo-job] key outputs:"
echo "  - ${RESULTS_DIR}/comparison.csv"
echo "  - ${RESULTS_DIR}/cuckoo_stats.csv"
echo "  - ${RESULTS_DIR}/timing.csv"
echo "  - ${RESULTS_DIR}/benchmark_log.txt"
