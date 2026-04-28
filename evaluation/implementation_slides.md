---
marp: true
theme: default
paginate: true
size: 16:9
title: Adaptive Cuckoo Hash Join in DuckDB
headingDivider: 1
---

# Adaptive Cuckoo Hash Join in DuckDB
## Implementation Details

- Project goal: build a practical cuckoo-hash-based join backend inside DuckDB
- Main challenge: textbook cuckoo hashing is not robust enough for analytical database workloads
- Implementation evolved from a plain prototype to an adaptive hybrid backend
- This section focuses on that engineering evolution

# 1. Plain Implementation

- Start from a minimal cuckoo join backend integrated into DuckDB
- Each key is mapped to a small set of candidate positions and inserted with simple kickout logic
- Probe path checks only the candidate locations in the main table
- Backend selection is exposed through `hash_join_backend`, so the operator can switch between linear and cuckoo
- Goal of this stage: prove correctness and wire the new backend into `PhysicalHashJoin`

**Key property**
- Simple and functional, but still close to a textbook cuckoo hash table

# 2. Problems Exposed by the Plain Version

- **Insertion instability:** long kickout chains make build time unpredictable
- **Skew sensitivity:** hot keys repeatedly collide in the same few buckets
- **Duplicate-heavy joins:** database joins are not simple key-value inserts; duplicates amplify pressure
- **Rehash cost:** rebuilding a large join table is much more expensive than in a standalone hash map
- **Poor worst-case behavior:** some queries regress badly even when average lookup is acceptable

**Conclusion**
- The plain implementation was correct, but not robust enough for real analytical workloads

# 3. What We Borrowed from RocksDB

- We did **not** copy RocksDB directly; we used it as an engineering reference
- **Bucketized / locality-aware layout:** prefer bucket-level placement instead of purely slot-level logic
- **Bounded insertion effort:** do not allow unlimited displacement chains
- **Auxiliary structures:** hard insertions should have side paths instead of immediate failure
- **Tunable parameters:** practical cuckoo hashing needs configuration knobs, not fixed constants

**Why this was not enough by itself**
- RocksDB is a key-value storage setting, while DuckDB hash join must handle duplicates, skew, and query-time fallback

# 4. Improvement 1: Block-Based Bucket Layout

- **Problem:** slot-level probing causes scattered memory access and weak locality
- **Change:** organize the table as buckets with multiple slots instead of isolated single-slot placement
- **Implementation:** a hash maps to candidate bucket blocks, and insert/probe scan slots inside the block first
- **Why it helps:** most checks stay within one small contiguous region, improving cache locality
- **Effect:** lookup becomes more stable and better aligned with database join access patterns

**Takeaway**
- This is the first step from textbook cuckoo hashing toward an engine-friendly layout

# 5. Improvement 2: BFS Relocation Instead of Naive Kickout

- **Problem:** naive kickout is greedy and can bounce entries around without finding a good placement path
- **Change:** replace local/random displacement with bounded BFS-based relocation
- **Implementation:** explore candidate relocation paths and choose a feasible short path when one exists
- **Why it helps:** reduces wasted kickouts and improves insertion success under pressure
- **Effect:** build-side behavior becomes much more stable than the plain implementation

**Tradeoff**
- BFS adds control overhead, so it must be bounded by a search-depth limit

# 6. Improvement 3: Victim Cache, Stash, and Overflow Paths

- **Problem:** “insert or rehash” is too brittle for skewed and duplicate-heavy join workloads
- **Change:** add multi-stage side structures for difficult insertions
- **Implementation:**
  - victim cache for temporarily displaced entries
  - stash for unresolved collisions
  - overflow structure for entries that should not force immediate rehash
- **Why it helps:** transforms insertion failure into a managed multi-stage pipeline
- **Effect:** fewer catastrophic rebuilds and much better robustness on hard queries

**Takeaway**
- The backend becomes hybrid, not a pure cuckoo table anymore

# 7. Improvement 4: Adaptive Tuning

- **Problem:** one fixed load factor and one fixed search policy do not fit all workloads
- **Change:** dynamically tune parameters based on runtime behavior and workload characteristics
- **Implementation:**
  - adjust target load factor according to collision and kickout behavior
  - react to duplicate ratio and effective skew
  - retune search depth and stash pressure limits
- **Why it helps:** uniform workloads can stay aggressive, while skewed workloads become more conservative
- **Effect:** the final backend is much more stable across JOB and TPC-DS queries

**Key idea**
- Different queries need different cuckoo policies

# 8. Improvement 5: Graceful Fallback to Linear Probing

- **Problem:** some workloads are fundamentally unfriendly to cuckoo hashing
- **Change:** stop forcing cuckoo when pressure becomes too high
- **Implementation:** detect stash pressure, rehash pressure, and kickout pressure; then fall back to DuckDB's linear backend
- **Why it helps:** prevents extreme tail latency and protects worst-case performance
- **Effect:** the backend behaves like an adaptive hybrid system rather than an all-or-nothing prototype

**Most important lesson**
- The goal is not to always use cuckoo; the goal is to use cuckoo only when it is beneficial

# 9. Summary: What These Changes Solved

- Started from a **plain cuckoo implementation** that was correct but fragile
- Used **RocksDB-inspired engineering ideas** as a reference for practical cuckoo design
- Added **block-based buckets** to improve locality
- Added **BFS relocation** to control insertion instability
- Added **victim / stash / overflow paths** to avoid brittle failure behavior
- Added **adaptive tuning** to react to skew and workload differences
- Added **fallback to linear probing** to bound worst-case regressions

**Final result**
- We ended with an **adaptive hybrid cuckoo join backend** specialized for analytical database workloads, not just a textbook cuckoo hash table
