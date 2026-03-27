//===----------------------------------------------------------------------===//
//                         DuckDB
//
// duckdb/execution/cuckoo_join_hashtable.hpp
//
//===----------------------------------------------------------------------===//

#pragma once

#include "duckdb/common/common.hpp"
#include "duckdb/common/enums/join_type.hpp"
#include "duckdb/common/typedefs.hpp"
#include <vector>

namespace duckdb {

class ClientContext;

//! Lightweight cuckoo hash table used by the experimental hash join backend.
class CuckooJoinHashTable {
public:
	explicit CuckooJoinHashTable(idx_t initial_capacity = 0);

	//! Resets all buckets/stash entries.
	void Reset();

	//! Ensure the table can hold at least `count` entries without rehashing.
	void Reserve(idx_t count);

	//! Insert a row pointer identified by the already-computed hash.
	//! Returns true on success, false if the table/stash overflowed even after a rehash.
	bool Insert(hash_t hash, data_ptr_t row_ptr);

	//! Number of stored entries (buckets + stash).
	idx_t Size() const {
		return size;
	}

	idx_t Capacity() const {
		return capacity;
	}

	idx_t StashSize() const {
		return stash.size();
	}

	idx_t Kickouts() const {
		return total_kickouts;
	}

	idx_t Rehashes() const {
		return rehash_count;
	}

private:
	struct Bucket {
		hash_t hash;
		data_ptr_t row_ptr;
	};

private:
	std::vector<Bucket> buckets;
	std::vector<Bucket> stash;

	idx_t capacity;
	idx_t mask;
	idx_t size;

	const idx_t kickout_limit = 32;
	const idx_t stash_limit = 64;
	double max_load_factor = 0.9;

	idx_t total_kickouts = 0;
	idx_t rehash_count = 0;

private:
	void Grow(idx_t new_capacity);
	bool InsertOrRehash(hash_t hash, data_ptr_t row_ptr, bool allow_rehash);
	bool TryPlace(idx_t slot, hash_t hash, data_ptr_t row_ptr);
	bool Kickout(idx_t slot, hash_t hash, data_ptr_t row_ptr);
	void PushToStash(hash_t hash, data_ptr_t row_ptr);
	void Rehash(idx_t new_capacity);

	idx_t PrimarySlot(hash_t hash) const;
	idx_t SecondarySlot(hash_t hash) const;
	idx_t AlternateSlot(hash_t hash, idx_t current_slot) const;
};

} // namespace duckdb
