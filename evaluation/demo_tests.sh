#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_DIR=${BUILD_DIR:-"${ROOT_DIR}/build/release"}
DUCKDB_BIN=${DUCKDB_BIN:-"${BUILD_DIR}/duckdb"}
HARNESS_SCRIPT=${HARNESS_SCRIPT:-"${ROOT_DIR}/evaluation/test_cuckoo_join_backend.sh"}
BENCH_SCRIPT=${BENCH_SCRIPT:-"${ROOT_DIR}/evaluation/bench_hash_backend.sh"}
ROW_COUNT=${ROW_COUNT:-500000}

if [[ ! -x "${DUCKDB_BIN}" ]]; then
  echo "error: DuckDB binary not found at '${DUCKDB_BIN}'. Run evaluation/demo_build_and_enable.sh first." >&2
  exit 1
fi

echo "[demo-tests] 1/2 correctness harness"
bash "${HARNESS_SCRIPT}"

echo
echo "[demo-tests] 2/2 small benchmark sanity check (ROW_COUNT=${ROW_COUNT})"
WORK_DIR=$(mktemp -d -t cuckoo-demo-test-XXXXXX)
cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

DB_FILE="${WORK_DIR}/bench.duckdb" ROW_COUNT="${ROW_COUNT}" bash "${BENCH_SCRIPT}"

echo
echo "[demo-tests] success: correctness and timing sanity checks completed"
