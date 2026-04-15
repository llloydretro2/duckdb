# Evaluation Scripts

This directory collects the scripts used to validate and benchmark the cuckoo
hash join backend.

Common prerequisites:

- Build DuckDB first so `build/release/duckdb` exists, or override
  `DUCKDB_BIN`.
- Provide the expected local datasets/databases when running JOB or TPC-DS
  related scripts.
- Most scripts write their outputs into benchmark result directories in the
  repository root; those result directories are intentionally gitignored.

Scripts:

- `test_cuckoo_join_backend.sh`: basic backend correctness harness.
- `bench_hash_backend.sh`: small synthetic hash join timing sanity check.
- `synthetic_cuckoo_perf.sh`: synthetic workload generator and profiler.
- `job_cuckoo_perf.sh`: focused JOB join microbenchmarks.
- `job_queries_ab_perf.sh`: alternating-order JOB A/B benchmark.
- `job_queries_cuckoo_ab.sh`: full JOB benchmark with profiling summaries.
- `job_queries_cuckoo_focus.sh`: targeted JOB regressions benchmark.
- `job_queries_cuckoo_perf.sh`: per-query JOB EXPLAIN/profile runner.
- `job_query_profile.sh`: focused profiler for problematic JOB queries.
- `run_phase3_validation.sh`: combined validation entry point.
- `generate_tpcds_schema.py`: helper for generating TPC-DS schema assets.
- `generate_tpcds_results.py`: helper for aggregating TPC-DS result output.
- `tpcds_profile_compare.py`: runs TPC-DS queries on both backends and extracts cuckoo profiling counters.
