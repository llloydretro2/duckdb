#!/usr/bin/env bash
#
# Join Order Benchmark (JOB) query harness for comparing DuckDB hash join backends.
# Runs each SQL query twice per backend with alternating order to mitigate warm caches.
#
# Configurable environment variables (defaults shown):
#   DUCKDB_BIN=./build/release/duckdb   -- DuckDB executable
#   JOB_DB_PATH=data/job/imdb.duckdb    -- DuckDB database file containing JOB data
#   QUERY_DIR=data/job/job_queries      -- directory of *.sql workload files
#   RESULTS_DIR=job_query_benchmark     -- destination for logs/metrics
#   THREADS=4                           -- PRAGMA threads value
#   RUN_TIMEOUT=600                     -- timeout per query/backend (seconds)
#   SLEEP_BETWEEN=2                     -- pause (seconds) between individual runs
#
set -euo pipefail

DUCKDB_BIN=${DUCKDB_BIN:-"./build/release/duckdb"}
JOB_DB_PATH=${JOB_DB_PATH:-"data/job/imdb.duckdb"}
QUERY_DIR=${QUERY_DIR:-"data/job/job_queries"}
RESULTS_DIR=${RESULTS_DIR:-"job_query_benchmark"}
THREADS=${THREADS:-4}
RUN_TIMEOUT=${RUN_TIMEOUT:-600}
SLEEP_BETWEEN=${SLEEP_BETWEEN:-2}
TIMEOUT_BIN=${TIMEOUT_BIN:-""}

if [[ ! -x "${DUCKDB_BIN}" ]]; then
  echo "error: DuckDB binary not found at '${DUCKDB_BIN}'" >&2
  exit 1
fi
if [[ ! -f "${JOB_DB_PATH}" ]]; then
  echo "error: DuckDB database not found at '${JOB_DB_PATH}'" >&2
  exit 1
fi
if [[ ! -d "${QUERY_DIR}" ]]; then
  echo "error: query directory '${QUERY_DIR}' not found" >&2
  exit 1
fi

rm -rf "${RESULTS_DIR}"
mkdir -p "${RESULTS_DIR}"

OUTPUT_FILE="${RESULTS_DIR}/benchmark_log.txt"
TIMING_FILE="${RESULTS_DIR}/timing.csv"
COMPARISON_FILE="${RESULTS_DIR}/comparison.csv"

printf "query_file,loop,backend,start_time,end_time,duration_ms,status\n" >"${TIMING_FILE}"
printf "query_file,avg_linear_ms,avg_cuckoo_ms,delta_ms,delta_percent\n" >"${COMPARISON_FILE}"

if [[ -z "${TIMEOUT_BIN}" ]]; then
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN=$(command -v timeout)
  elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN=$(command -v gtimeout)
  else
    TIMEOUT_BIN=""
    echo "[job-bench] warning: neither timeout nor gtimeout found; RUN_TIMEOUT will be ignored" | tee -a "${OUTPUT_FILE}"
  fi
fi

SQL_FILES=()
while IFS= read -r line; do
  SQL_FILES+=("${line}")
done < <(find "${QUERY_DIR}" -type f -name "*.sql" | sort -V)

if [[ ${#SQL_FILES[@]} -eq 0 ]]; then
  echo "error: no SQL files found under ${QUERY_DIR}" >&2
  exit 1
fi

TOTAL_FILES=${#SQL_FILES[@]}

abs_path() {
  local path="$1"
  if [[ "${path}" == /* ]]; then
    echo "${path}"
  else
    echo "$(pwd)/${path}"
  fi
}

for i in "${!SQL_FILES[@]}"; do
  SQL_FILES[$i]=$(abs_path "${SQL_FILES[$i]}")
done

log() {
  printf '%s\n' "$*" | tee -a "${OUTPUT_FILE}"
}

run_duckdb_query() {
  local backend="$1"
  local sql_path="$2"
  local loop_id="$3"
  local tag="$4" # e.g. linear_loop1
  local base_name
  base_name=$(basename "${sql_path}")
  local stdout_file="${RESULTS_DIR}/${base_name}_${tag}.out"
  local stderr_file="${RESULTS_DIR}/${base_name}_${tag}.err"

  local start_epoch_ms end_epoch_ms duration status start_human end_human
  start_epoch_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
  start_human=$(date '+%Y-%m-%d %H:%M:%S')

  local cmd_status=0
  local tmp_sql
  tmp_sql=$(mktemp -t job-query-XXXX.sql)
  python3 - "${sql_path}" "${tmp_sql}" <<'PY'
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()

def fix_alias(text):
    pattern = re.compile(r'(?i)(\baka_title\b\s+(?:AS\s+)?)(at\b)')
    text = pattern.sub(lambda m: m.group(1) + "aka_title_alias", text)
    text = re.sub(r'(?i)\bat\.', 'aka_title_alias.', text)
    return text

pathlib.Path(sys.argv[2]).write_text(fix_alias(src))
PY

  local tmp_wrapper
  tmp_wrapper=$(mktemp -t job-wrapper-XXXX.sql)
  cat >"${tmp_wrapper}" <<EOF
.timer on
PRAGMA enable_progress_bar=false;
PRAGMA threads=${THREADS};
SET hash_join_backend='${backend}';
EOF
  cat "${tmp_sql}" >>"${tmp_wrapper}"

  if [[ -n "${TIMEOUT_BIN}" ]]; then
    "${TIMEOUT_BIN}" "${RUN_TIMEOUT}" "${DUCKDB_BIN}" "${JOB_DB_PATH}" <"${tmp_wrapper}" >"${stdout_file}" 2>"${stderr_file}"
    cmd_status=$?
  else
    "${DUCKDB_BIN}" "${JOB_DB_PATH}" <"${tmp_wrapper}" >"${stdout_file}" 2>"${stderr_file}"
    cmd_status=$?
  fi

  rm -f "${tmp_sql}" "${tmp_wrapper}"
  if [[ ${cmd_status} -eq 0 ]]; then
    status="SUCCESS"
  else
    status="FAILED"
  fi

  end_epoch_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
  end_human=$(date '+%Y-%m-%d %H:%M:%S')
  duration=$((end_epoch_ms - start_epoch_ms))

  printf '%s,%s,%s,%s,%s,%s,%s\n' "${sql_path}" "${loop_id}" "${backend}" "${start_human}" "${end_human}" "${duration}" "${status}" >>"${TIMING_FILE}"
  log "    ${backend} duration: ${duration} ms (${status})"
}

log "Join Order Benchmark query run started $(date)"
log "Database: ${JOB_DB_PATH}"
log "Queries: ${TOTAL_FILES} files under ${QUERY_DIR}"
log "Results directory: ${RESULTS_DIR}"
log "================================================"

loop_queries() {
  local first_backend="$1"
  local second_backend="$2"
  local loop_id="$3"
  local idx=0
  for sql_path in "${SQL_FILES[@]}"; do
    idx=$((idx + 1))
    log "[Loop ${loop_id}] (${idx}/${TOTAL_FILES}) ${sql_path}"
    log "  -> backend=${first_backend}"
    run_duckdb_query "${first_backend}" "${sql_path}" "${loop_id}" "${first_backend}_loop${loop_id}"
    sleep "${SLEEP_BETWEEN}"
    log "  -> backend=${second_backend}"
    run_duckdb_query "${second_backend}" "${sql_path}" "${loop_id}" "${second_backend}_loop${loop_id}"
    log ""
    sleep "${SLEEP_BETWEEN}"
  done
}

log "Loop 1: cuckoo first, then linear"
loop_queries "cuckoo" "linear" 1
log "Loop 2: linear first, then cuckoo"
loop_queries "linear" "cuckoo" 2

log "================================================"
log "Calculating averages"

python3 - "${TIMING_FILE}" "${COMPARISON_FILE}" <<'PY' | tee -a "${OUTPUT_FILE}"
import csv, math, sys
from collections import defaultdict

_, timing_path, comparison_path = sys.argv
durations = defaultdict(list)
queries = set()

with open(timing_path, newline='') as f:
    reader = csv.DictReader(f)
    for row in reader:
        key = (row["query_file"], row["backend"])
        queries.add(row["query_file"])
        if row["status"] == "SUCCESS":
            try:
                durations[key].append(int(row["duration_ms"]))
            except ValueError:
                pass

queries = sorted(queries)

with open(comparison_path, "a", newline='') as cmp:
    writer = csv.writer(cmp)
    for query in queries:
        lin_vals = durations.get((query, "linear"), [])
        cuck_vals = durations.get((query, "cuckoo"), [])
        avg_linear = sum(lin_vals) // len(lin_vals) if lin_vals else -1
        avg_cuckoo = sum(cuck_vals) // len(cuck_vals) if cuck_vals else -1
        if avg_linear >= 0 and avg_cuckoo >= 0:
            delta = avg_linear - avg_cuckoo
            delta_percent = f"{(delta * 100 / avg_linear):.2f}" if avg_linear else "0.00"
            summary = (f"{query}: linear={avg_linear} ms, "
                       f"cuckoo={avg_cuckoo} ms, delta={delta} ms ({delta_percent}%)")
        else:
            delta = ""
            delta_percent = ""
            summary = f"{query}: insufficient successful runs to compute averages"
        writer.writerow([query, avg_linear, avg_cuckoo, delta, delta_percent])
        print(summary)
PY

log "================================================"
log "Finished at $(date)"
log "Timing CSV: ${TIMING_FILE}"
log "Comparison CSV: ${COMPARISON_FILE}"
log "Per-query outputs saved under ${RESULTS_DIR}/*.out"
