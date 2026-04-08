#!/usr/bin/env bash
#
# Iterate over JOB (IMDb) query files and compare Linear vs Cuckoo backends.
# Requires data/job/imdb.duckdb and SQL files under data/job/job_queries/*.sql.
#
set -euo pipefail

DUCKDB_BIN=${DUCKDB_BIN:-"./build/release/duckdb"}
JOB_DB=${JOB_DB:-"data/job/imdb.duckdb"}
BACKENDS=${BACKENDS:-"linear cuckoo"}
QUERY_DIR=${QUERY_DIR:-"data/job/job_queries"}
OUT_DIR=${OUT_DIR:-"job_queries_perf"}
mkdir -p "${OUT_DIR}"

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

SCRATCH_DIR=$(mktemp -d -t job-query-cuckoo-XXXXXX)
cleanup() {
  rm -rf "${SCRATCH_DIR}"
}
trap cleanup EXIT

log() {
  echo "[JOB-Queries] $*"
}

profile_json() {
  python3 - "$@"
}

run_query() {
  local backend="$1"
  local query_file="$2"
  local base
  base=$(basename "${query_file}")
  local label="${base%.sql}_${backend}"
  local explain_file="${OUT_DIR}/${label}_explain.txt"
  local profile_tmp="${SCRATCH_DIR}/${label}_profile.json"
  local profile_summary="${OUT_DIR}/${label}_profile_summary.json"
  local sql
  sql=$(cat "${query_file}")

  log "Query=${base} backend=${backend}"

  /usr/bin/time -p "${DUCKDB_BIN}" "${JOB_DB}" <<SQL 2>&1 | tee "${explain_file}"
PRAGMA enable_profiling=json;
SET hash_join_backend='${backend}';
EXPLAIN ANALYZE ${sql}
PRAGMA disable_profiling;
SQL

  if python3 - "${explain_file}" "${profile_tmp}" "${profile_summary}" <<'PY'
import json, sys
src, dst, summary_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, 'r', encoding='utf-8', errors='ignore') as fi:
    data = fi.read()
objects = []
depth = 0
start = None
for idx, ch in enumerate(data):
    if ch == '{':
        if depth == 0:
            start = idx
        depth += 1
    elif ch == '}':
        if depth == 0:
            continue
        depth -= 1
        if depth == 0 and start is not None:
            chunk = data[start:idx + 1]
            try:
                obj = json.loads(chunk)
            except json.JSONDecodeError:
                start = None
                continue
            objects.append(obj)
            start = None
if not objects:
    raise SystemExit(1)
profile = objects[-1]
def find_hash_join(node):
    if isinstance(node, dict):
        if node.get("operator_name") == "HASH_JOIN":
            return node
        for child in node.get("children", []) or []:
            res = find_hash_join(child)
            if res:
                return res
    elif isinstance(node, list):
        for item in node:
            res = find_hash_join(item)
            if res:
                return res
    return None
hash_join = find_hash_join(profile)
with open(dst, 'w', encoding='utf-8') as fo:
    json.dump(profile, fo)
summary = {}
if hash_join:
    extra = hash_join.get("extra_info") or {}
    summary = {
        "hash_backend": extra.get("Hash Join Backend"),
        "cuckoo_load_factor": extra.get("Cuckoo Load Factor"),
        "cuckoo_capacity": extra.get("Cuckoo Capacity"),
        "cuckoo_entries": extra.get("Cuckoo Entries"),
        "cuckoo_bucket_slots": extra.get("Cuckoo Bucket Slots"),
        "cuckoo_stash_entries": extra.get("Cuckoo Stash Entries"),
        "cuckoo_stash_high_watermark": extra.get("Cuckoo Stash High Watermark"),
        "cuckoo_kickouts": extra.get("Cuckoo Kickouts"),
        "cuckoo_rehashes": extra.get("Cuckoo Rehashes"),
        "cuckoo_fallback_events": extra.get("Cuckoo Fallback Events"),
        "operator_cardinality": hash_join.get("operator_cardinality"),
        "operator_timing_seconds": hash_join.get("operator_timing"),
    }
with open(summary_path, 'w', encoding='utf-8') as fo:
    json.dump(summary, fo)
PY
  then
    log "  profile summary stored at ${profile_summary}"
  else
    log "  WARNING: profiling JSON not found in ${explain_file}"
  fi
}

shopt -s nullglob
query_files=("${QUERY_DIR}"/*.sql)
if [[ ${#query_files[@]} -eq 0 ]]; then
  echo "error: no .sql files found under ${QUERY_DIR}" >&2
  exit 1
fi

for backend in ${BACKENDS}; do
  for query in "${query_files[@]}"; do
    run_query "${backend}" "${query}"
  done
done

log "Done. Results stored under ${OUT_DIR}."
