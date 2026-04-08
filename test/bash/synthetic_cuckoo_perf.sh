#!/usr/bin/env bash
#
# Synthetic workload generator + perf harness for the cuckoo hash join backend.
# Quickly creates configurable build/probe tables directly inside DuckDB and
# measures both LINEAR and CUCKOO hash join behavior under several scenarios.
#
# Tunable env vars (with defaults):
#   DUCKDB_BIN=./build/release/duckdb   -- DuckDB executable
#   ROWS=2000000                        -- rows per table
#   KEY_DOMAIN=4096                     -- cardinality of join keys
#   THREADS=4                           -- PRAGMA threads during generation/probe
#   SCENARIOS="uniform high_dup skewed" -- which scenarios to run
#   BACKENDS="linear cuckoo"            -- join backends to test
#   DUP_DOMAIN_FACTOR=8                 -- domain shrink factor for high_dup
#   SKEW_POWER=4                        -- exponent for skewed key generation
#   NULL_FREQ=0                         -- every Nth key becomes NULL (0 disables)
#   OUT_DIR="synthetic_perf"            -- where to dump profiles/explain logs
#
set -euo pipefail

DUCKDB_BIN=${DUCKDB_BIN:-"./build/release/duckdb"}
if [[ ! -x "${DUCKDB_BIN}" ]]; then
  echo "error: DuckDB binary not found at '${DUCKDB_BIN}'" >&2
  exit 1
fi

ROWS=${ROWS:-2000000}
KEY_DOMAIN=${KEY_DOMAIN:-4096}
THREADS=${THREADS:-4}
SCENARIOS=${SCENARIOS:-"uniform high_dup skewed"}
BACKENDS=${BACKENDS:-"linear cuckoo"}
DUP_DOMAIN_FACTOR=${DUP_DOMAIN_FACTOR:-8}
SKEW_POWER=${SKEW_POWER:-4}
NULL_FREQ=${NULL_FREQ:-0}
OUT_DIR=${OUT_DIR:-"synthetic_perf"}
CACHE_DATASETS=${CACHE_DATASETS:-0}
CACHE_DIR=${CACHE_DIR:-"${OUT_DIR}/datasets"}
REUSE_CACHE=${REUSE_CACHE:-1}
mkdir -p "${OUT_DIR}"
if [[ "${CACHE_DATASETS}" -ne 0 ]]; then
  mkdir -p "${CACHE_DIR}"
fi

SCRATCH_DIR=$(mktemp -d -t cuckoo-synth-XXXXXX)
cleanup() {
  rm -rf "${SCRATCH_DIR}"
}
trap cleanup EXIT
DB_PATH="${SCRATCH_DIR}/synthetic.duckdb"

scenario_fs_id() {
  local raw="$1"
  raw="${raw//[^A-Za-z0-9._-]/_}"
  echo "${raw}"
}

scenario_cache_path() {
  local scenario="$1"
  local fs_id
  fs_id=$(scenario_fs_id "${scenario}")
  echo "${CACHE_DIR}/${fs_id}.duckdb"
}

try_restore_cache() {
  local scenario="$1"
  if [[ "${CACHE_DATASETS}" -eq 0 ]]; then
    return 1
  fi
  local cache_path
  cache_path=$(scenario_cache_path "${scenario}")
  if [[ -f "${cache_path}" && "${REUSE_CACHE}" -ne 0 ]]; then
    log "  cache hit for scenario='${scenario}', restoring dataset"
    cp "${cache_path}" "${DB_PATH}"
    return 0
  fi
  return 1
}

persist_cache() {
  local scenario="$1"
  if [[ "${CACHE_DATASETS}" -eq 0 ]]; then
    return
  fi
  local cache_path
  cache_path=$(scenario_cache_path "${scenario}")
  cp "${DB_PATH}" "${cache_path}"
  log "  cached dataset stored at ${cache_path}"
}

log() {
  echo "[Synthetic] $*"
}

run_sql() {
  local sql="$1"
  "${DUCKDB_BIN}" "${DB_PATH}" <<'SQL'
PRAGMA enable_progress_bar=false;
SQL
  "${DUCKDB_BIN}" "${DB_PATH}" <<SQL >/dev/null
PRAGMA threads=${THREADS};
${sql}
SQL
}

collect_metrics() {
  local backend="$1"
  local output
  output=$("${DUCKDB_BIN}" -csv -header "${DB_PATH}" <<SQL
PRAGMA threads=${THREADS};
SET hash_join_backend='${backend}';
SELECT COUNT(*) AS match_count, SUM(key) AS key_checksum FROM probe p JOIN build b USING (key);
SQL
)
  output=$(printf "%s\n" "${output}" | grep -v '^$' | tail -n 1)
  IFS=',' read -r match_count key_checksum <<<"${output}"
  echo "${match_count},${key_checksum}"
}

generate_uniform() {
  log "Preparing uniform data (ROWS=${ROWS}, KEY_DOMAIN=${KEY_DOMAIN})"
  run_sql "
  DROP TABLE IF EXISTS build;
  DROP TABLE IF EXISTS probe;
  CREATE TABLE build AS
  SELECT i AS row_id,
         CASE WHEN ${NULL_FREQ} > 0 AND (i % ${NULL_FREQ}) = 0 THEN NULL
              ELSE (i % ${KEY_DOMAIN}) END AS key,
         random() AS payload
  FROM range(${ROWS}) t(i);

  CREATE TABLE probe AS
  SELECT i AS row_id,
         CASE WHEN ${NULL_FREQ} > 0 AND (i % ${NULL_FREQ}) = 0 THEN NULL
              ELSE (i % ${KEY_DOMAIN}) END AS key
  FROM range(${ROWS}) t(i);
  "
}

generate_high_dup() {
  local dup_domain=$(( KEY_DOMAIN / DUP_DOMAIN_FACTOR ))
  if [[ ${dup_domain} -lt 1 ]]; then
    dup_domain=1
  fi
  log "Preparing high-duplicate data (domain=${dup_domain})"
  run_sql "
  DROP TABLE IF EXISTS build;
  DROP TABLE IF EXISTS probe;
  CREATE TABLE build AS
  SELECT i AS row_id,
         CASE WHEN ${NULL_FREQ} > 0 AND (i % ${NULL_FREQ}) = 0 THEN NULL
              ELSE (i % ${dup_domain}) END AS key,
         random() AS payload
  FROM range(${ROWS}) t(i);

  CREATE TABLE probe AS
  SELECT i AS row_id,
         CASE WHEN ${NULL_FREQ} > 0 AND (i % ${NULL_FREQ}) = 0 THEN NULL
              ELSE (i % ${dup_domain}) END AS key
  FROM range(${ROWS}) t(i);
  "
}

effective_skew_power() {
  local scenario="$1"
  if [[ "${scenario}" =~ ^skewed_p([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  echo "${SKEW_POWER}"
}

generate_skewed() {
  local scenario="$1"
  local power
  power=$(effective_skew_power "${scenario}")
  log "Preparing skewed data (power=${power})"
  run_sql "
  DROP TABLE IF EXISTS build;
  DROP TABLE IF EXISTS probe;
  CREATE TABLE build AS
  SELECT i AS row_id,
         CASE WHEN ${NULL_FREQ} > 0 AND (i % ${NULL_FREQ}) = 0 THEN NULL
              ELSE CAST(floor(pow(random(), ${power}) * ${KEY_DOMAIN}) AS INTEGER) END AS key,
         random() AS payload
  FROM range(${ROWS}) t(i);

  CREATE TABLE probe AS
  SELECT i AS row_id,
         CASE WHEN ${NULL_FREQ} > 0 AND (i % ${NULL_FREQ}) = 0 THEN NULL
              ELSE CAST(floor(pow(random(), ${power}) * ${KEY_DOMAIN}) AS INTEGER) END AS key
  FROM range(${ROWS}) t(i);
  "
}

prepare_scenario() {
  local scenario="$1"
  if try_restore_cache "${scenario}"; then
    return
  fi
  case "${scenario}" in
    uniform) generate_uniform ;;
    high_dup) generate_high_dup ;;
    skewed|skewed_p*) generate_skewed "${scenario}" ;;
    *)
      echo "error: unknown scenario '$1'" >&2
      exit 1
      ;;
  esac
  persist_cache "${scenario}"
}

run_backend() {
  local scenario="$1"
  local backend="$2"
  local scenario_id
  scenario_id=$(scenario_fs_id "${scenario}")
  local explain_file="${OUT_DIR}/${scenario_id}_${backend}_explain.txt"
  local metrics_file="${OUT_DIR}/${scenario_id}_${backend}_metrics.txt"
  local baseline_file="${OUT_DIR}/${scenario_id}_baseline_metrics.txt"
  local profile_tmp="${SCRATCH_DIR}/${scenario}_${backend}_profile.json"
  local profile_file="${OUT_DIR}/${scenario_id}_${backend}_profile.json"
  local profile_summary="${OUT_DIR}/${scenario_id}_${backend}_profile_summary.json"

  log "Scenario=${scenario} backend=${backend}"

  local metrics
  metrics=$(collect_metrics "${backend}")
  IFS=',' read -r match_count key_checksum <<<"${metrics}"
  printf "%s\n%s\n" "match_count=${match_count}" "key_checksum=${key_checksum}"
  echo "${metrics}" >"${metrics_file}"

  if [[ "${backend}" == "linear" ]]; then
    cp "${metrics_file}" "${baseline_file}"
  elif [[ -f "${baseline_file}" ]]; then
    IFS=',' read -r base_count base_checksum <"${baseline_file}"
    if [[ "${match_count}" != "${base_count}" || "${key_checksum}" != "${base_checksum}" ]]; then
      log "WARNING: metrics mismatch vs linear baseline (scenario=${scenario}, backend=${backend})"
      log "         expected count=${base_count}, checksum=${base_checksum}"
    fi
  else
    log "  (no linear baseline available for scenario=${scenario}, skipping comparison)"
  fi

  /usr/bin/time -p "${DUCKDB_BIN}" "${DB_PATH}" <<SQL 2>&1 | tee "${explain_file}"
PRAGMA threads=${THREADS};
SET hash_join_backend='${backend}';
PRAGMA enable_profiling=json;
EXPLAIN ANALYZE SELECT COUNT(*) FROM probe p JOIN build b USING (key);
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
    cp "${profile_tmp}" "${profile_file}"
    log "  profile summary stored at ${profile_summary}"
  else
    log "  WARNING: profiling JSON not found at ${profile_tmp}"
  fi
  log "  explain output stored at ${explain_file}"
}

for scenario in ${SCENARIOS}; do
  prepare_scenario "${scenario}"
  for backend in ${BACKENDS}; do
    run_backend "${scenario}" "${backend}"
  done
done

log "Done. Inspect ${OUT_DIR} for EXPLAIN outputs per scenario/backend."
