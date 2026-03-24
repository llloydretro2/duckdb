//===----------------------------------------------------------------------===//
//                         DuckDB
//
// duckdb/execution/cuckoo_join_hashtable.cpp
//
//===----------------------------------------------------------------------===//

#include "duckdb/execution/cuckoo_join_hashtable.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/main/client_context.hpp"
#include "duckdb/execution/operator/join/physical_hash_join.hpp"

namespace duckdb {

CuckooJoinHashTable::CuckooJoinHashTable(ClientContext &, const PhysicalHashJoin &, const vector<JoinCondition> &,
                                         const vector<LogicalType> &, JoinType, idx_t) {
	throw NotImplementedException(
	    "CuckooJoinHashTable is a placeholder. The CUCKOO hash join backend has not been implemented yet.");
}

CuckooJoinHashTable::~CuckooJoinHashTable() {
}

} // namespace duckdb
