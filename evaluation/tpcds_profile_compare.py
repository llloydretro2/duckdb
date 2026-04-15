from __future__ import annotations

import csv
import json
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any


ROOT_DIR = Path(__file__).resolve().parents[1]
DUCKDB_BIN = ROOT_DIR / "build/release/duckdb"
DB_PATH = ROOT_DIR / "tpcds_sf1.duckdb"
QUERY_DIR = ROOT_DIR / "extension/tpcds/dsdgen/queries"
OUTPUT_CSV = ROOT_DIR / "tpcds_profile_compare.csv"

# Leave empty to run all queries, or fill with a subset like:
# SELECTED_QUERIES = {"01.sql", "03.sql", "05.sql"}
SELECTED_QUERIES: set[str] = set()

# Number of repeated runs per backend per query.
REPEATS = 1


def discover_queries() -> list[Path]:
    queries = sorted(QUERY_DIR.glob("*.sql"))
    if SELECTED_QUERIES:
        queries = [q for q in queries if q.name in SELECTED_QUERIES]
    return queries


def try_parse_json_blob(text: str) -> dict[str, Any] | None:
    start = text.find("{")
    while start != -1:
        depth = 0
        for offset, ch in enumerate(text[start:]):
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    snippet = text[start : start + offset + 1]
                    try:
                        parsed = json.loads(snippet)
                        if isinstance(parsed, dict):
                            return parsed
                    except json.JSONDecodeError:
                        break
        start = text.find("{", start + 1)
    return None


def iter_hash_joins(node: Any):
    if isinstance(node, dict):
        operator_type = node.get("operator_type") or node.get("operator_name")
        if operator_type == "HASH_JOIN":
            yield node
        for child in node.get("children", []):
            yield from iter_hash_joins(child)
    elif isinstance(node, list):
        for item in node:
            yield from iter_hash_joins(item)


def parse_number(value: Any) -> Any:
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


def extract_hash_join_stats(output_text: str) -> dict[str, Any]:
    profile = try_parse_json_blob(output_text)
    if not profile:
        return {
            "load_factor": "",
            "target_load_factor": "",
            "kickouts": "",
            "max_kickout_depth": "",
            "bfs_failures": "",
            "stash_entries": "",
            "stash_hwm": "",
            "overflow_entries": "",
            "victim_entries": "",
            "victim_mode": "",
        }

    joins = list(iter_hash_joins(profile))
    if not joins:
        return {
            "load_factor": "",
            "target_load_factor": "",
            "kickouts": "",
            "max_kickout_depth": "",
            "bfs_failures": "",
            "stash_entries": "",
            "stash_hwm": "",
            "overflow_entries": "",
            "victim_entries": "",
            "victim_mode": "",
        }

    chosen = max(joins, key=lambda j: j.get("operator_timing", 0))
    info = chosen.get("extra_info", {})

    return {
        "load_factor": parse_number(info.get("Cuckoo Load Factor")),
        "target_load_factor": parse_number(info.get("Cuckoo Target Load Factor")),
        "kickouts": parse_number(info.get("Cuckoo Kickouts")),
        "max_kickout_depth": parse_number(info.get("Cuckoo Max Kickout Depth")),
        "bfs_failures": parse_number(info.get("Cuckoo BFS Failures")),
        "stash_entries": parse_number(info.get("Cuckoo Stash Entries")),
        "stash_hwm": parse_number(info.get("Cuckoo Stash High Watermark")),
        "overflow_entries": parse_number(info.get("Cuckoo Overflow Entries")),
        "victim_entries": parse_number(info.get("Cuckoo Victim Entries")),
        "victim_mode": info.get("Cuckoo Victim Mode", ""),
    }


def build_sql_script(query_sql: str, backend: str) -> str:
    return f"""
PRAGMA enable_progress_bar=false;
PRAGMA enable_profiling=json;
SET hash_join_backend='{backend}';
{query_sql}
"""


def run_query_once(query_path: Path, backend: str) -> tuple[float, dict[str, Any], str]:
    query_sql = query_path.read_text(encoding="utf-8")
    script = build_sql_script(query_sql, backend)

    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as tmp:
        tmp.write(script)
        tmp_path = Path(tmp.name)

    try:
        start = time.perf_counter()
        with tmp_path.open("r", encoding="utf-8") as stdin_file:
            result = subprocess.run(
                [str(DUCKDB_BIN), str(DB_PATH)],
                stdin=stdin_file,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
        elapsed = time.perf_counter() - start

        combined_output = (result.stdout or "") + "\n" + (result.stderr or "")
        stats = extract_hash_join_stats(combined_output)

        if result.returncode != 0:
            raise RuntimeError(
                f"Query {query_path.name} failed for backend={backend}\n"
                f"STDERR:\n{result.stderr}\nSTDOUT:\n{result.stdout}"
            )

        return elapsed, stats, combined_output
    finally:
        tmp_path.unlink(missing_ok=True)


def average(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def pct_change_vs_linear(linear: float, cuckoo: float) -> float:
    if linear == 0:
        return 0.0
    return ((linear - cuckoo) / linear) * 100.0


def winner(linear: float, cuckoo: float) -> str:
    if cuckoo < linear:
        return "cuckoo"
    if linear < cuckoo:
        return "linear"
    return "tie"


def main() -> None:
    if not DUCKDB_BIN.exists():
        raise FileNotFoundError(f"DuckDB binary not found: {DUCKDB_BIN}")
    if not DB_PATH.exists():
        raise FileNotFoundError(f"TPC-DS DB not found: {DB_PATH}")
    if not QUERY_DIR.exists():
        raise FileNotFoundError(f"TPC-DS query dir not found: {QUERY_DIR}")

    queries = discover_queries()
    if not queries:
        raise RuntimeError("No query files found.")

    with OUTPUT_CSV.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "query",
                "linear_real_s",
                "cuckoo_real_s",
                "delta_s",
                "pct_change_vs_linear",
                "winner",
                "cuckoo_load_factor",
                "cuckoo_target_load_factor",
                "cuckoo_kickouts",
                "cuckoo_max_kickout_depth",
                "cuckoo_bfs_failures",
                "cuckoo_stash_entries",
                "cuckoo_stash_hwm",
                "cuckoo_overflow_entries",
                "cuckoo_victim_entries",
                "cuckoo_victim_mode",
            ]
        )

        for query_index, query_file in enumerate(queries):
            print(f"Running {query_file.name}...")

            linear_runs: list[float] = []
            cuckoo_runs: list[float] = []
            final_cuckoo_stats: dict[str, Any] = {}

            # Alternate order slightly to reduce warm-cache bias.
            backends = ["linear", "cuckoo"] if query_index % 2 == 0 else ["cuckoo", "linear"]

            for _ in range(REPEATS):
                for backend in backends:
                    elapsed, stats, _output = run_query_once(query_file, backend)
                    if backend == "linear":
                        linear_runs.append(elapsed)
                    else:
                        cuckoo_runs.append(elapsed)
                        final_cuckoo_stats = stats

            linear_time = average(linear_runs)
            cuckoo_time = average(cuckoo_runs)
            delta = cuckoo_time - linear_time
            pct = pct_change_vs_linear(linear_time, cuckoo_time)

            writer.writerow(
                [
                    query_file.name,
                    f"{linear_time:.6f}",
                    f"{cuckoo_time:.6f}",
                    f"{delta:.6f}",
                    f"{pct:.2f}",
                    winner(linear_time, cuckoo_time),
                    final_cuckoo_stats.get("load_factor", ""),
                    final_cuckoo_stats.get("target_load_factor", ""),
                    final_cuckoo_stats.get("kickouts", ""),
                    final_cuckoo_stats.get("max_kickout_depth", ""),
                    final_cuckoo_stats.get("bfs_failures", ""),
                    final_cuckoo_stats.get("stash_entries", ""),
                    final_cuckoo_stats.get("stash_hwm", ""),
                    final_cuckoo_stats.get("overflow_entries", ""),
                    final_cuckoo_stats.get("victim_entries", ""),
                    final_cuckoo_stats.get("victim_mode", ""),
                ]
            )

    print(f"Done. Wrote results to {OUTPUT_CSV}")


if __name__ == "__main__":
    main()
