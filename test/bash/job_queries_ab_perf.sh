#!/usr/bin/env bash
#
# JOB query benchmark comparing DuckDB linear vs cuckoo hash join backends.
# Runs each SQL twice in alternating orders to reduce warm-up bias and logs timing CSVs.
#
set -euo pipefail

DUCKDB_BIN=${DUCKDB_BIN:-"./build/release/duckdb"}
JOB_DB=${JOB_DB:-"data/job/imdb.duckdb"}
QUERY_DIR=${QUERY_DIR:-"data/job/job_queries"}
BACKEND_A=${BACKEND_A:-"linear"}  # first backend in each sequence
BACKEND_B=${BACKEND_B:-"cuckoo"}  # second backend
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-0} # 0 disables timeout
RESULTS_DIR=${RESULTS_DIR:-"job_query_benchmark"}
OUTPUT_FILE="query_benchmark_results.txt"
TIMING_FILE="query_timing.csv"
COMPARISON_FILE="performance_comparison.csv"

if [[ ! -x "${DUCKDB_BIN}" ]]; then
  echo "error: DuckDB binary not found at '${DUCKDB_BIN}'" >&2
  exit 1
fi
if [[ ! -f "${JOB_DB}" ]]; then
  echo "error: JOB database not found at '${JOB_DB}'" >&2
  exit 1
fi
if [[ ! -d "${QUERY_DIR}" ]]; then
  echo "error: query directory '${QUERY_DIR}' not found" >&2
  exit 1
fi

rm -rf "${RESULTS_DIR}"
mkdir -p "${RESULTS_DIR}"
: >"${RESULTS_DIR}/${OUTPUT_FILE}"
: >"${RESULTS_DIR}/${TIMING_FILE}"
: >"${RESULTS_DIR}/${COMPARISON_FILE}"

echo "query_file,test_round,backend,start_time,end_time,duration_ms,status" >>"${RESULTS_DIR}/${TIMING_FILE}"
echo "query_file,${BACKEND_A}_avg_ms,${BACKEND_B}_avg_ms,improvement_ms,improvement_percent,loop1_order,loop2_order" >>"${RESULTS_DIR}/${COMPARISON_FILE}"

log() {
  echo "$*" | tee -a "${RESULTS_DIR}/${OUTPUT_FILE}"
}

log "================================================"
log "JOB query benchmark started: $(date)"
log "Database: ${JOB_DB}"
log "Queries from: ${QUERY_DIR}"
log "Comparing backends: ${BACKEND_A} vs ${BACKEND_B}"
log "Results directory: ${RESULTS_DIR}"
log "================================================"

mapfile -t QUERY_FILES < <(find "${QUERY_DIR}" -name "*.sql" | sort -V)
TOTAL_FILES=${#QUERY_FILES[@]}
if [[ ${TOTAL_FILES} -eq 0 ]]; then
  log "No SQL files found under ${QUERY_DIR}"
  exit 1
fi

declare -A Round1A Round1B Round2A Round2B

run_duckdb() {
  local backend="$1"
  local sql_file="$2"
  local loop="$3"
  local order_label="$4"
  local base
  base=$(basename "${sql_file}")
  local result_file="${RESULTS_DIR}/${base}_${backend}_${order_label}.result"
  local error_file="${RESULTS_DIR}/${base}_${backend}_${order_label}.error"

  local sql_text
  sql_text=$(cat "${sql_file}")

  local start_ms
  start_ms=$(date +%s%3N)
  local start_readable
  start_readable=$(date '+%Y-%m-%d %H:%M:%S.%3N')

  local status="SUCCESS"
  if [[ ${TIMEOUT_SECONDS} -gt 0 ]]; then
    if ! timeout "${TIMEOUT_SECONDS}" "${DUCKDB_BIN}" "${JOB_DB}" <<SQL >"${result_file}" 2>"${error_file}"
PRAGMA enable_profiling=json;
SET hash_join_backend='${backend}';
${sql_text}
PRAGMA disable_profiling;
SQL
    then
      status="FAILED"
    fi
  else
    if ! "${DUCKDB_BIN}" "${JOB_DB}" <<SQL >"${result_file}" 2>"${error_file}"
PRAGMA enable_profiling=json;
SET hash_join_backend='${backend}';
${sql_text}
PRAGMA disable_profiling;
SQL
    then
      status="FAILED"
    fi
  fi

  local end_ms
  end_ms=$(date +%s%3N)
  local end_readable
  end_readable=$(date '+%Y-%m-%d %H:%M:%S.%3N')
  local duration_ms=$((end_ms - start_ms))

  echo "${sql_file},${loop},${backend},${start_readable},${end_readable},${duration_ms},${status}" >>"${RESULTS_DIR}/${TIMING_FILE}"

  echo "${order_label} backend=${backend} duration=${duration_ms}ms status=${status}" >>"${RESULTS_DIR}/${OUTPUT_FILE}"

  printf "%s" "${duration_ms}"
}

# Loop 1: BACKEND_A first, BACKEND_B second
log "=== LOOP 1: ${BACKEND_A} first, then ${BACKEND_B} ==="
INDEX=0
for sql_file in "${QUERY_FILES[@]}"; do
  INDEX=$((INDEX + 1))
  log "[${INDEX}/${TOTAL_FILES}] ${sql_file}"

  duration_a=$(run_duckdb "${BACKEND_A}" "${sql_file}" 1 "loop1_${BACKEND_A}")
  Round1A["${sql_file}"]=${duration_a}
  sleep 1
  duration_b=$(run_duckdb "${BACKEND_B}" "${sql_file}" 1 "loop1_${BACKEND_B}")
  Round1B["${sql_file}"]=${duration_b}
  sleep 3
done

# Loop 2: BACKEND_B first, BACKEND_A second
log "=== LOOP 2: ${BACKEND_B} first, then ${BACKEND_A} ==="
INDEX=0
for sql_file in "${QUERY_FILES[@]}"; do
  INDEX=$((INDEX + 1))
  log "[${INDEX}/${TOTAL_FILES}] ${sql_file}"

  duration_b=$(run_duckdb "${BACKEND_B}" "${sql_file}" 2 "loop2_${BACKEND_B}")
  Round2B["${sql_file}"]=${duration_b}
  sleep 1
  duration_a=$(run_duckdb "${BACKEND_A}" "${sql_file}" 2 "loop2_${BACKEND_A}")
  Round2A["${sql_file}"]=${duration_a}
  sleep 3
done

log "=== SUMMARY ==="

for sql_file in "${QUERY_FILES[@]}"; do
  base=$(basename "${sql_file}")
  a1=${Round1A["${sql_file}"]:-0}
  a2=${Round2A["${sql_file}"]:-0}
  b1=${Round1B["${sql_file}"]:-0}
  b2=${Round2B["${sql_file}"]:-0}
  avg_a=$(( (a1 + a2) / 2 ))
  avg_b=$(( (b1 + b2) / 2 ))
  improvement=$((avg_b - avg_a))
  if [[ ${avg_b} -ne 0 ]]; then
    improvement_pct=$(python3 - <<PY
import sys
avg_b=${avg_b}
impr=${improvement}
print(f"{(impr*100/avg_b):.2f}")
PY
)
  else
    improvement_pct="0.00"
  fi

  if [[ ${improvement} -gt 0 ]]; then
    verdict="${BACKEND_A} faster by ${improvement}ms (${improvement_pct}%)"
  elif [[ ${improvement} -lt 0 ]]; then
    abs_impr=$((-improvement))
    pct=${improvement_pct#-}
    verdict="${BACKEND_B} faster by ${abs_impr}ms (${pct}%)"
  else
    verdict="Both backends equal"
  fi

  log "${base}: ${BACKEND_A} avg=${avg_a}ms, ${BACKEND_B} avg=${avg_b}ms -> ${verdict}"
  echo "${sql_file},${avg_a},${avg_b},${improvement},${improvement_pct},${BACKEND_A}_then_${BACKEND_B},${BACKEND_B}_then_${BACKEND_A}" >>"${RESULTS_DIR}/${COMPARISON_FILE}"
done

log "Benchmark finished: $(date)"
log "Timing CSV: ${RESULTS_DIR}/${TIMING_FILE}"
log "Comparison CSV: ${RESULTS_DIR}/${COMPARISON_FILE}"
log "Detailed logs stored under ${RESULTS_DIR}"
