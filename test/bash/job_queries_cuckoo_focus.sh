#!/usr/bin/env bash
#
# Focused JOB benchmark runner that targets a handful of skew-heavy queries
# and records detailed Cuckoo/linear hash join statistics.
#
# Environment variables (override as needed):
#   DUCKDB_BIN=./build/release/duckdb
#   JOB_DB_PATH=data/job/imdb.duckdb
#   QUERY_DIR=data/job/job_queries
#   RESULTS_DIR=job_query_focus
#   THREADS=4
#   RUN_TIMEOUT=600                # seconds
#   SLEEP_BETWEEN=1                # seconds between runs
#   FOCUS_QUERIES="6f.sql 21a.sql 3c.sql 31b.sql 4c.sql"
#
set -euo pipefail

DUCKDB_BIN=${DUCKDB_BIN:-"./build/release/duckdb"}
JOB_DB_PATH=${JOB_DB_PATH:-"data/job/imdb.duckdb"}
QUERY_DIR=${QUERY_DIR:-"data/job/job_queries"}
RESULTS_DIR=${RESULTS_DIR:-"job_query_focus"}
THREADS=${THREADS:-4}
RUN_TIMEOUT=${RUN_TIMEOUT:-600}
SLEEP_BETWEEN=${SLEEP_BETWEEN:-1}
FOCUS_QUERIES=${FOCUS_QUERIES:-"6f.sql 21a.sql 3c.sql 31b.sql 4c.sql"}
TIMEOUT_BIN=${TIMEOUT_BIN:-""}

if [[ ! -x "${DUCKDB_BIN}" ]]; then
	echo "error: DuckDB binary not found at '${DUCKDB_BIN}'" >&2
	exit 1
fi
if [[ ! -f "${JOB_DB_PATH}" ]]; then
	echo "error: JOB database '${JOB_DB_PATH}' not found" >&2
	exit 1
fi
if [[ ! -d "${QUERY_DIR}" ]]; then
	echo "error: query directory '${QUERY_DIR}' not found" >&2
	exit 1
fi

if [[ -z "${TIMEOUT_BIN}" ]]; then
	if command -v timeout >/dev/null 2>&1; then
		TIMEOUT_BIN=$(command -v timeout)
	elif command -v gtimeout >/dev/null 2>&1; then
		TIMEOUT_BIN=$(command -v gtimeout)
	else
		echo "[job-focus] warning: timeout utility not found; RUN_TIMEOUT disabled" >&2
	fi
fi

rm -rf "${RESULTS_DIR}"
mkdir -p "${RESULTS_DIR}"

LOG_FILE="${RESULTS_DIR}/focus_log.txt"
TIMING_CSV="${RESULTS_DIR}/focus_timings.csv"
SUMMARY_CSV="${RESULTS_DIR}/focus_summary.csv"

printf "query_file,backend,start_time,end_time,duration_ms,status,load_factor,target_load_factor,kickouts,max_kickout_depth,bfs_failures,stash_entries,stash_hwm,overflow_entries,victim_entries,victim_mode\n" >"${TIMING_CSV}"
printf "query_file,linear_ms,cuckoo_ms,delta_ms,delta_percent\n" >"${SUMMARY_CSV}"

log() {
	printf '%s\n' "$*" | tee -a "${LOG_FILE}"
}

abs_path() {
	local path="$1"
	if [[ "${path}" == /* ]]; then
		echo "${path}"
	else
		echo "$(pwd)/${path}"
	fi
}

prepare_query() {
	local src_path="$1"
	local tmp_path="$2"
	python3 - "${src_path}" "${tmp_path}" <<'PY'
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
pattern = re.compile(r'(?i)(\baka_title\b\s+(?:AS\s+)?)(at\b)')
src = pattern.sub(lambda m: m.group(1) + "aka_title_alias", src)
src = re.sub(r'(?i)\bat\.', 'aka_title_alias.', src)
pathlib.Path(sys.argv[2]).write_text(src)
PY
}

run_query() {
	local backend="$1"
	local query_file="$2"
	local base_name
	base_name=$(basename "${query_file}")
	local stdout_file="${RESULTS_DIR}/${base_name}_${backend}.out"
	local stderr_file="${RESULTS_DIR}/${base_name}_${backend}.err"

	local tmp_sql tmp_wrapper
	tmp_sql=$(mktemp -t job-focus-sql-XXXX.sql)
	tmp_wrapper=$(mktemp -t job-focus-wrapper-XXXX.sql)
	prepare_query "${query_file}" "${tmp_sql}"
	cat >"${tmp_wrapper}" <<EOF
.timer on
PRAGMA enable_progress_bar=false;
PRAGMA threads=${THREADS};
PRAGMA enable_profiling=json;
SET hash_join_backend='${backend}';
EOF
	cat "${tmp_sql}" >>"${tmp_wrapper}"

	local start_ms end_ms duration status start_human end_human
	start_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
	start_human=$(date '+%Y-%m-%d %H:%M:%S')
	if [[ -n "${TIMEOUT_BIN}" ]]; then
		if ! "${TIMEOUT_BIN}" "${RUN_TIMEOUT}" "${DUCKDB_BIN}" "${JOB_DB_PATH}" <"${tmp_wrapper}" >"${stdout_file}" 2>"${stderr_file}"; then
			status="FAILED"
		else
			status="SUCCESS"
		fi
	else
		if ! "${DUCKDB_BIN}" "${JOB_DB_PATH}" <"${tmp_wrapper}" >"${stdout_file}" 2>"${stderr_file}"; then
			status="FAILED"
		else
			status="SUCCESS"
		fi
	fi
	end_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
	end_human=$(date '+%Y-%m-%d %H:%M:%S')
	duration=$((end_ms - start_ms))

	JOB_FOCUS_LOG="${LOG_FILE}" python3 - "${stdout_file}" "${stderr_file}" "${TIMING_CSV}" "${query_file}" "${backend}" "${start_human}" "${end_human}" "${duration}" "${status}" <<'PY'
import csv, json, os, sys
stdout_path, stderr_path, csv_path, query_path, backend, start_ts, end_ts, duration, status = sys.argv[1:]
duration = int(duration)
def try_parse(text):
    start = text.find('{')
    while start != -1:
        depth = 0
        for offset, ch in enumerate(text[start:]):
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    snippet = text[start:start + offset + 1]
                    try:
                        return json.loads(snippet)
                    except json.JSONDecodeError:
                        break
        start = text.find('{', start + 1)
    return None

def iter_joins(node):
    if isinstance(node, dict):
        if node.get("operator_type") == "HASH_JOIN" or node.get("operator_name") == "HASH_JOIN":
            yield node
        for child in node.get("children", []):
            yield from iter_joins(child)

def parse_number(value):
    if value in ("", None):
        return ""
    if isinstance(value, (int, float)):
        return value
    text = str(value).strip().replace("%", "")
    try:
        if "." in text:
            return float(text)
        return int(text)
    except ValueError:
        return text

def read_file(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""

stats = {"load_factor": "", "target": "", "kickouts": "", "max_depth": "", "bfs": "",
         "stash_entries": "", "stash_hwm": "", "overflow": "", "victim_entries": "", "victim_mode": ""}
profile = try_parse(read_file(stdout_path)) or try_parse(read_file(stderr_path))
chosen = None
if profile:
    joins = list(iter_joins(profile))
    if joins:
        chosen = max(joins, key=lambda n: n.get("operator_timing", 0))
if chosen:
    info = chosen.get("extra_info", {})
    stats["load_factor"] = parse_number(info.get("Cuckoo Load Factor"))
    stats["target"] = parse_number(info.get("Cuckoo Target Load Factor"))
    stats["kickouts"] = parse_number(info.get("Cuckoo Kickouts"))
    stats["max_depth"] = parse_number(info.get("Cuckoo Max Kickout Depth"))
    stats["bfs"] = parse_number(info.get("Cuckoo BFS Failures"))
    stats["stash_entries"] = parse_number(info.get("Cuckoo Stash Entries"))
    stats["stash_hwm"] = parse_number(info.get("Cuckoo Stash High Watermark"))
    stats["overflow"] = parse_number(info.get("Cuckoo Overflow Entries"))
    stats["victim_entries"] = parse_number(info.get("Cuckoo Victim Entries"))
    stats["victim_mode"] = info.get("Cuckoo Victim Mode", "")

with open(csv_path, "a", newline='') as out:
    writer = csv.writer(out)
    writer.writerow([
        query_path, backend, start_ts, end_ts, duration, status,
        stats["load_factor"], stats["target"], stats["kickouts"], stats["max_depth"], stats["bfs"],
        stats["stash_entries"], stats["stash_hwm"], stats["overflow"], stats["victim_entries"], stats["victim_mode"]
    ])
def as_float(value):
    return value if isinstance(value, (int, float)) else None

if backend == "cuckoo":
    warnings = []
    load_val = as_float(stats["load_factor"])
    target_val = as_float(stats["target"])
    kickouts_val = as_float(stats["kickouts"])
    overflow_val = as_float(stats["overflow"])
    if kickouts_val and target_val and load_val and kickouts_val > 0 and load_val < target_val * 0.9:
        warnings.append(f"kickouts={int(kickouts_val)} with load {load_val:.2f}% < 90% of target {target_val:.2f}%")
    if overflow_val and overflow_val > 0:
        warnings.append(f"overflow entries={int(overflow_val)}")
    if not warnings and load_val and load_val < 35.0:
        warnings.append(f"low load factor {load_val:.2f} despite zero kickouts")
    log_path = os.environ.get("JOB_FOCUS_LOG")
    for msg in warnings:
        line = f"[warn] {query_path} {backend}: {msg}"
        print(line)
        if log_path:
            with open(log_path, "a", encoding="utf-8") as log:
                log.write(line + "\n")
PY

	log "  ${backend}: ${duration} ms (${status})"
	rm -f "${tmp_sql}" "${tmp_wrapper}"
}

read -r -a query_tokens <<<"${FOCUS_QUERIES}"
if [[ ${#query_tokens[@]} -eq 0 ]]; then
	echo "error: no queries specified in FOCUS_QUERIES" >&2
	exit 1
fi

log "Focused JOB run started $(date)"
log "Database: ${JOB_DB_PATH}"
log "Queries: ${#query_tokens[@]} under ${QUERY_DIR}"
log "Results directory: ${RESULTS_DIR}"
log "================================================"

for query in "${query_tokens[@]}"; do
	query_path="${QUERY_DIR}/${query}"
	if [[ ! -f "${query_path}" ]]; then
		echo "error: query '${query}' not found under ${QUERY_DIR}" >&2
		exit 1
	fi
	abs_query=$(abs_path "${query_path}")
	log ">>> ${query}"
	run_query "cuckoo" "${abs_query}"
	sleep "${SLEEP_BETWEEN}"
	run_query "linear" "${abs_query}"
	log ""
	sleep "${SLEEP_BETWEEN}"
done

python3 - "${TIMING_CSV}" "${SUMMARY_CSV}" <<'PY'
import csv, sys, collections
timing_csv, summary_csv = sys.argv[1:3]
records = collections.defaultdict(dict)
with open(timing_csv, newline='') as fh:
    reader = csv.DictReader(fh)
    for row in reader:
        records[row["query_file"]][row["backend"]] = int(row["duration_ms"])

with open(summary_csv, "a", newline='') as fh:
    writer = csv.writer(fh)
    for query in sorted(records):
        linear = records[query].get("linear")
        cuckoo = records[query].get("cuckoo")
        if linear is None or cuckoo is None:
            writer.writerow([query, linear or "", cuckoo or "", "", ""])
            continue
        delta = linear - cuckoo
        pct = (delta * 100 / linear) if linear else 0.0
        writer.writerow([query, linear, cuckoo, delta, f"{pct:.2f}"])
PY

log "================================================"
log "Completed at $(date)"
log "Timing CSV: ${TIMING_CSV}"
log "Summary CSV: ${SUMMARY_CSV}"
log "Detailed outputs stored under ${RESULTS_DIR}"
