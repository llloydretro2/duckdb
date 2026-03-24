//===----------------------------------------------------------------------===//
//                         DuckDB
//
// duckdb/common/enums/hash_join_backend.hpp
//
//===----------------------------------------------------------------------===//

#pragma once

#include <cstdint>

namespace duckdb {

enum class HashJoinBackend : uint8_t {
	LINEAR = 0,
	CUCKOO = 1
};

}
