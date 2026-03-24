//===----------------------------------------------------------------------===//
//                         DuckDB
//
// duckdb/execution/cuckoo_join_hashtable.hpp
//
//===----------------------------------------------------------------------===//

#pragma once

#include "duckdb/common/common.hpp"
#include "duckdb/common/enums/join_type.hpp"
#include "duckdb/common/types.hpp"
#include <vector>

namespace duckdb {

class ClientContext;
class PhysicalHashJoin;
struct JoinCondition;

//! Placeholder for the future cuckoo-hash-based join hash table backend.
class CuckooJoinHashTable {
public:
	CuckooJoinHashTable(ClientContext &context, const PhysicalHashJoin &op, const vector<JoinCondition> &conditions,
	                    const vector<LogicalType> &build_types, JoinType join_type, idx_t initial_radix_bits);
	~CuckooJoinHashTable();
};

} // namespace duckdb
