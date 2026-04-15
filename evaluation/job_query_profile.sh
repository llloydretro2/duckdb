#!/usr/bin/env bash
#
# Focused profiler for troublesome JOB queries.
# For each query it runs both linear & cuckoo hash join backends,
# captures EXPLAIN ANALYZE output, JSON profile, and emits a compact CSV summary.
#
# Env vars (defaults):
#   DUCKDB_BIN=<repo>/build/release/duckdb
#   JOB_DB_PATH=<repo>/data/job/imdb.duckdb
#   QUERY_DIR=<repo>/data/job/job_queries
#   RESULTS_DIR=<repo>/job_query_profiles
#   THREADS=4
#   BACKENDS="linear cuckoo"
#   FOCUS_QUERIES="6f.sql 3c.sql 19d.sql 7c.sql 1a.sql"
#
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DUCKDB_BIN=${DUCKDB_BIN:-"${ROOT_DIR}/build/release/duckdb"}
JOB_DB_PATH=${JOB_DB_PATH:-"${ROOT_DIR}/data/job/imdb.duckdb"}
QUERY_DIR=${QUERY_DIR:-"${ROOT_DIR}/data/job/job_queries"}
RESULTS_DIR=${RESULTS_DIR:-"${ROOT_DIR}/job_query_profiles"}
THREADS=${THREADS:-4}
BACKENDS=${BACKENDS:-"linear cuckoo"}
FOCUS_QUERIES=${FOCUS_QUERIES:-"6f.sql 3c.sql 19d.sql 7c.sql 1a.sql"}

if [[ ! -x "${DUCKDB_BIN}" ]]; then
  echo "error: DuckDB binary '${DUCKDB_BIN}' not found or not executable" >&2
  exit 1
fi
if [[ ! -f "${JOB_DB_PATH}" ]]; then
  echo "error: database '${JOB_DB_PATH}' not found" >&2
  exit 1
fi
if [[ ! -d "${QUERY_DIR}" ]]; then
  echo "error: query directory '${QUERY_DIR}' not found" >&2
  exit 1
fi

rm -rf "${RESULTS_DIR}"
mkdir -p "${RESULTS_DIR}"

SUMMARY_CSV="${RESULTS_DIR}/summary.csv"
printf "query,backend,status,duration_ms,latency_s,cpu_time_s,hash_join_time_s,hash_join_rows,cuckoo_kickouts,cuckoo_rehashes,cuckoo_stash_hwm,cuckoo_overflow_entries,cuckoo_overflow_hwm\n" > "${SUMMARY_CSV}"

abs_path() {
  local path="$1"
  if [[ "${path}" == /* ]]; then
    echo "${path}"
  else
    echo "$(pwd)/${path}"
  fi
}

python_extract() {
  local profile_json="$1"
  local stdout_file="$2"
  local csv_path="$3"
  local query="$4"
  local backend="$5"
  local status="$6"
  local duration_ms="$7"
  python3 - "${profile_json}" "${stdout_file}" "${csv_path}" "${query}" "${backend}" "${status}" "${duration_ms}" <<'PY'
import json, sys, csv, os, pathlib
profile_path, stdout_path, csv_path, query, backend, status, duration = sys.argv[1:8]
latency = cpu_time = ""
agg = {
    "hash_join_time": "",
    "hash_join_rows": "",
    "kickouts": "",
    "rehashes": "",
    "stash_hwm": "",
    "overflow_entries": "",
    "overflow_hwm": "",
}

def load_profile():
    if os.path.exists(profile_path):
        with open(profile_path) as f:
            return json.load(f)
    if os.path.exists(stdout_path):
        text = pathlib.Path(stdout_path).read_text()
        start = text.find("{")
        end = text.rfind("}")
        if start != -1 and end != -1 and end > start:
            try:
                return json.loads(text[start:end + 1])
            except json.JSONDecodeError:
                return {}
    return {}

def try_record(node):
    if agg["hash_join_time"]:
        return
    agg["hash_join_time"] = node.get("operator_timing", "")
    agg["hash_join_rows"] = node.get("cumulative_cardinality", "")
    extra = node.get("extra_info", {}) or {}
    agg["kickouts"] = extra.get("Cuckoo Kickouts", "")
    agg["rehashes"] = extra.get("Cuckoo Rehashes", "")
    agg["stash_hwm"] = extra.get("Cuckoo Stash High Watermark", "")
    agg["overflow_entries"] = extra.get("Cuckoo Overflow Entries", "")
    agg["overflow_hwm"] = extra.get("Cuckoo Overflow High Watermark", "")

def walk(node):
    if not isinstance(node, dict):
        return
    if node.get("operator_name") == "HASH_JOIN" and not agg["hash_join_time"]:
        try_record(node)
    for child in node.get("children", []) or []:
        walk(child)

data = load_profile()
if data:
    latency = data.get("latency", "")
    cpu_time = data.get("cpu_time", "")
    for child in data.get("children", []):
        walk(child)

with open(csv_path, "a", newline='') as f:
    writer = csv.writer(f)
    writer.writerow([
        query, backend, status, duration, latency, cpu_time,
        agg["hash_join_time"], agg["hash_join_rows"], agg["kickouts"],
        agg["rehashes"], agg["stash_hwm"], agg["overflow_entries"], agg["overflow_hwm"],
    ])
PY
}

fix_query_alias() {
  local src="$1"
  local dst="$2"
  python3 - "${src}" "${dst}" <<'PY'
import pathlib, re, sys
src, dst = sys.argv[1:3]
text = pathlib.Path(src).read_text()
pattern = re.compile(r'(?i)(\baka_title\b\s+(?:AS\s+)?)(at\b)')
text = pattern.sub(lambda m: m.group(1) + "aka_title_alias", text)
text = re.sub(r'(?i)\bat\.', 'aka_title_alias.', text)
pathlib.Path(dst).write_text(text)
PY
}

run_query_backend() {
  local sql_path="$1"
  local backend="$2"
  local base_name
  base_name=$(basename "${sql_path}")
  local stem="${base_name%.*}_${backend}"
  local profile_json="${RESULTS_DIR}/${stem}.json"
  local explain_txt="${RESULTS_DIR}/${stem}_explain.txt"
  local stdout_file="${RESULTS_DIR}/${stem}.out"
  local stderr_file="${RESULTS_DIR}/${stem}.err"

  local tmp_sql tmp_wrapper
  tmp_sql=$(mktemp -t job-focus-XXXX.sql)
  tmp_wrapper=$(mktemp -t job-focus-wrapper-XXXX.sql)
  fix_query_alias "${sql_path}" "${tmp_sql}"
  cat > "${tmp_wrapper}" <<EOF
.timer on
PRAGMA enable_progress_bar=false;
PRAGMA enable_profiling='json';
PRAGMA profile_output='${profile_json}';
PRAGMA profiling_mode='detailed';
PRAGMA threads=${THREADS};
SET hash_join_backend='${backend}';
EXPLAIN ANALYZE
EOF
  cat "${tmp_sql}" >> "${tmp_wrapper}"

  local start_ms end_ms status
  start_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
  if "${DUCKDB_BIN}" "${JOB_DB_PATH}" < "${tmp_wrapper}" > "${stdout_file}" 2> "${stderr_file}"; then
    status="SUCCESS"
  else
    status="FAILED"
  fi
  end_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
  local duration_ms=$((end_ms - start_ms))

  sed -n '1,/^Run Time/p' "${stdout_file}" > "${explain_txt}" || true
  python_extract "${profile_json}" "${stdout_file}" "${SUMMARY_CSV}" "${sql_path}" "${backend}" "${status}" "${duration_ms}"

  rm -f "${tmp_sql}" "${tmp_wrapper}"
  printf "  [%s] %s -> %s (%s ms)\n" "${backend}" "$(basename "${sql_path}")" "${status}" "${duration_ms}"
}

echo "Focused JOB profiling started $(date)"
echo "Database: ${JOB_DB_PATH}"
echo "Queries: ${FOCUS_QUERIES}"
echo "Backends: ${BACKENDS}"
echo "Results dir: ${RESULTS_DIR}"
echo "----------------------------------------"

for query_file in ${FOCUS_QUERIES}; do
  full_path=$(abs_path "${QUERY_DIR}/${query_file}")
  if [[ ! -f "${full_path}" ]]; then
    echo "warning: query '${query_file}' not found under ${QUERY_DIR}, skipping" >&2
    continue
  fi
  echo ">>> ${query_file}"
  for backend in ${BACKENDS}; do
    run_query_backend "${full_path}" "${backend}"
  done
  echo ""
done

echo "Done. Summary stored at ${SUMMARY_CSV}"
