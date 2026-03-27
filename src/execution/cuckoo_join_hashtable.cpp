//===----------------------------------------------------------------------===//
//                         DuckDB
//
// duckdb/execution/cuckoo_join_hashtable.cpp
//
//===----------------------------------------------------------------------===//

#include "duckdb/execution/cuckoo_join_hashtable.hpp"

#include "duckdb/common/constants.hpp"
#include "duckdb/common/exception.hpp"
#include <cmath>
#include <utility>

namespace duckdb {

CuckooJoinHashTable::CuckooJoinHashTable(idx_t initial_capacity)
    : capacity(0), mask(0), size(0) {
	if (initial_capacity > 0) {
		Reserve(initial_capacity);
	}
}

void CuckooJoinHashTable::Reset() {
	for (auto &bucket : buckets) {
		bucket.hash = 0;
		bucket.row_ptr = nullptr;
	}
	stash.clear();
	size = 0;
	total_kickouts = 0;
}

void CuckooJoinHashTable::Reserve(idx_t count) {
	if (count == 0) {
		return;
	}
	auto required = static_cast<uint64_t>(std::ceil(static_cast<double>(count) / max_load_factor));
	const auto min_capacity = MaxValue<idx_t>(8, static_cast<idx_t>(NextPowerOfTwo(required)));
	if (min_capacity <= capacity) {
		return;
	}
	Rehash(min_capacity);
}

bool CuckooJoinHashTable::Insert(hash_t hash, data_ptr_t row_ptr) {
	if (capacity == 0) {
		Reserve(8);
	}
	if ((size + 1.0) > static_cast<double>(capacity) * max_load_factor) {
		Rehash(capacity * 2);
	}
	if (!InsertOrRehash(hash, row_ptr, true)) {
		return false;
	}
	size++;
	return true;
}

bool CuckooJoinHashTable::InsertOrRehash(hash_t hash, data_ptr_t row_ptr, bool allow_rehash) {
	auto slot1 = PrimarySlot(hash);
	if (TryPlace(slot1, hash, row_ptr)) {
		return true;
	}
	auto slot2 = SecondarySlot(hash);
	if (TryPlace(slot2, hash, row_ptr)) {
		return true;
	}
	if (Kickout(slot1, hash, row_ptr)) {
		return true;
	}
	if (allow_rehash) {
		Rehash(capacity * 2);
		return InsertOrRehash(hash, row_ptr, false);
	}
	return false;
}

bool CuckooJoinHashTable::TryPlace(idx_t slot, hash_t hash, data_ptr_t row_ptr) {
	auto &bucket = buckets[slot];
	if (bucket.hash == 0) {
		bucket.hash = hash;
		bucket.row_ptr = row_ptr;
		return true;
	}
	if (bucket.hash == hash) {
		// duplicate key: caller is expected to manage overflow chains
		return true;
	}
	return false;
}

bool CuckooJoinHashTable::Kickout(idx_t slot, hash_t hash, data_ptr_t row_ptr) {
	idx_t current_slot = slot;
	hash_t current_hash = hash;
	data_ptr_t current_ptr = row_ptr;

	for (idx_t kick = 0; kick < kickout_limit; kick++) {
		auto &victim = buckets[current_slot];
		std::swap(current_hash, victim.hash);
		std::swap(current_ptr, victim.row_ptr);
		total_kickouts++;

		current_slot = AlternateSlot(current_hash, current_slot);
		if (TryPlace(current_slot, current_hash, current_ptr)) {
			return true;
		}
	}

	PushToStash(current_hash, current_ptr);
	if (stash.size() > stash_limit) {
		return false;
	}
	return true;
}

void CuckooJoinHashTable::PushToStash(hash_t hash, data_ptr_t row_ptr) {
	stash.push_back({hash, row_ptr});
}

void CuckooJoinHashTable::Grow(idx_t new_capacity) {
	if (new_capacity <= capacity) {
		return;
	}
	Rehash(new_capacity);
}

void CuckooJoinHashTable::Rehash(idx_t new_capacity) {
	vector<Bucket> old_buckets = std::move(buckets);
	vector<Bucket> old_stash = std::move(stash);

	capacity = MaxValue<idx_t>(8, NextPowerOfTwo(new_capacity));
	mask = capacity - 1;
	buckets.clear();
	buckets.resize(capacity);
	for (auto &bucket : buckets) {
		bucket.hash = 0;
		bucket.row_ptr = nullptr;
	}
	stash.clear();
	size = 0;
	rehash_count++;

	for (auto &entry : old_buckets) {
		if (entry.hash == 0) {
			continue;
		}
		InsertOrRehash(entry.hash, entry.row_ptr, false);
		size++;
	}
	for (auto &entry : old_stash) {
		if (entry.hash == 0) {
			continue;
		}
		InsertOrRehash(entry.hash, entry.row_ptr, false);
		size++;
	}
}

idx_t CuckooJoinHashTable::PrimarySlot(hash_t hash) const {
	return mask ? (hash & mask) : 0;
}

idx_t CuckooJoinHashTable::SecondarySlot(hash_t hash) const {
	constexpr hash_t MIX_CONST = 0x9e3779b97f4a7c15ULL;
	auto mixed = (hash >> 32) ^ (hash * MIX_CONST);
	return mask ? (mixed & mask) : 0;
}

idx_t CuckooJoinHashTable::AlternateSlot(hash_t hash, idx_t current_slot) const {
	auto slot1 = PrimarySlot(hash);
	auto slot2 = SecondarySlot(hash);
	return current_slot == slot1 ? slot2 : slot1;
}

} // namespace duckdb
