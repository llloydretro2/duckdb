#!/usr/bin/env bash
#
# JOB-based workload driver for testing the cuckoo hash join backend.
# Requires a pre-built DuckDB binary and data/job/imdb.duckdb generated from the JOB dataset.
#
set -euo pipefail

DUCKDB_BIN=${DUCKDB_BIN:-"./build/release/duckdb"}
JOB_DB=${JOB_DB:-"data/job/imdb.duckdb"}
BACKENDS=${BACKENDS:-"linear cuckoo"}
SCENARIOS=${SCENARIOS:-"cast_title movie_keyword movie_companies info_type"}
OUT_DIR=${OUT_DIR:-"job_perf"}
mkdir -p "${OUT_DIR}"

if [[ ! -x "${DUCKDB_BIN}" ]]; then
  echo "error: DuckDB binary not found at '${DUCKDB_BIN}'" >&2
  exit 1
fi
if [[ ! -f "${JOB_DB}" ]]; then
  echo "error: JOB database not found at '${JOB_DB}'" >&2
  exit 1
fi

log() {
  echo "[JOB] $*"
}

SCRATCH_DIR=$(mktemp -d -t job-cuckoo-XXXXXX)
cleanup() {
  rm -rf "${SCRATCH_DIR}"
}
trap cleanup EXIT

WORKLOAD_KEYS=(
  "cast_title"
  "movie_keyword"
  "movie_companies"
  "info_type"
)
WORKLOAD_SQL()
{
  case "$1" in
    cast_title)
      echo "SELECT COUNT(*) FROM cast_info ci JOIN title t ON ci.movie_id = t.id"
      ;;
    movie_keyword)
      echo "SELECT COUNT(*) FROM movie_keyword mk JOIN keyword k ON mk.keyword_id = k.id"
      ;;
    movie_companies)
      echo "SELECT COUNT(*) FROM movie_companies mc JOIN company_name cn ON mc.company_id = cn.id"
      ;;
    info_type)
      echo "SELECT COUNT(*) FROM movie_info mi JOIN info_type it ON mi.info_type_id = it.id"
      ;;
    *)
      return 1
      ;;
  esac
}

run_workload() {
  local scenario="$1"
  local backend="$2"
  local sql
  if ! sql="$(WORKLOAD_SQL "${scenario}")"; then
    echo "error: unknown scenario '${scenario}'" >&2
    exit 1
  fi
  local label="${scenario}_${backend}"
  local explain_file="${OUT_DIR}/${label}_explain.txt"
  local profile_tmp="${SCRATCH_DIR}/${label}_profile.json"
  local profile_summary="${OUT_DIR}/${label}_profile_summary.json"

  log "Scenario=${scenario} backend=${backend}"

  /usr/bin/time -p "${DUCKDB_BIN}" "${JOB_DB}" <<SQL 2>&1 | tee "${explain_file}"
PRAGMA enable_profiling=json;
SET hash_join_backend='${backend}';
EXPLAIN ANALYZE ${sql};
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

for scenario in ${SCENARIOS}; do
  for backend in ${BACKENDS}; do
    run_workload "${scenario}" "${backend}"
  done
done

log "Done. Inspect ${OUT_DIR} for EXPLAIN/profiling outputs."
