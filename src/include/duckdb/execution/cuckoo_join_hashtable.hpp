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
#include "duckdb/common/unordered_map.hpp"
#include "duckdb/common/string_util.hpp"
#include <array>
#include <string>
#include <vector>

namespace duckdb {

class ClientContext;

enum CuckooFallbackReasonMask : uint8_t {
	CUCKOO_FALLBACK_NONE = 0,
	CUCKOO_FALLBACK_KICKOUT = 1 << 0,
	CUCKOO_FALLBACK_STASH = 1 << 1,
	CUCKOO_FALLBACK_REHASH = 1 << 2
};

struct CuckooTableConfig {
	double target_load_factor = 0.5;
	idx_t stash_scale = 64;
	idx_t min_stash = 64;
	idx_t bucket_slot_count = 4;
	idx_t max_search_depth = 32;
};

//! Lightweight cuckoo hash table used by the experimental hash join backend.
struct CuckooRuntimeStats {
	double load_factor = 0;
	idx_t capacity = 0;
	idx_t entries = 0;
	double target_load_factor = 0;
	idx_t bucket_slot_count = 0;
	idx_t block_size = 0;
	idx_t stash_entries = 0;
	idx_t stash_high_watermark = 0;
	idx_t overflow_entries = 0;
	idx_t overflow_high_watermark = 0;
	idx_t victim_entries = 0;
	idx_t victim_high_watermark = 0;
	idx_t kickouts = 0;
	idx_t max_kickout_depth = 0;
	idx_t bfs_failures = 0;
	idx_t rehashes = 0;
	idx_t fallback_events = 0;
	idx_t stash_limit = 0;
	idx_t kickout_limit = 0;
	idx_t hash_function_count = 0;
	uint8_t fallback_reason_mask = 0;
	bool victim_mode = false;
	bool backend_disabled = false;
};

inline string CuckooFallbackReasonToString(uint8_t mask) {
	if (mask == CUCKOO_FALLBACK_NONE) {
		return "none";
	}
	vector<string> reasons;
	if (mask & CUCKOO_FALLBACK_KICKOUT) {
		reasons.emplace_back("kickout_threshold");
	}
	if (mask & CUCKOO_FALLBACK_STASH) {
		reasons.emplace_back("stash_pressure");
	}
	if (mask & CUCKOO_FALLBACK_REHASH) {
		reasons.emplace_back("rehash_limit");
	}
	return StringUtil::Join(reasons, ",");
}

class CuckooJoinHashTable {
public:
	explicit CuckooJoinHashTable(const CuckooTableConfig &config = CuckooTableConfig{}, idx_t initial_capacity = 0);
	static constexpr idx_t MAX_LOOKUP_CANDIDATES = 512;
	static constexpr idx_t NUM_HASH_FUNCTIONS = 3;
	static constexpr idx_t BUCKET_SLOT_COUNT = 4;

	//! Resets all buckets/stash entries.
	void Reset();

	//! Apply a new configuration (load factor, stash scaling, etc.)
	void Configure(const CuckooTableConfig &config);

	//! Ensure the table can hold at least `count` entries without rehashing.
	void Reserve(idx_t count);

	//! Insert a row pointer identified by the already-computed hash.
	//! Returns true on success, false if the table/stash overflowed even after a rehash.
	bool Insert(hash_t hash, data_ptr_t pointer);

	//! Lookup returns up to max_results row pointers matching the hash
	idx_t Lookup(hash_t hash, data_ptr_t *results, idx_t max_results) const;

	double LoadFactor() const;
	CuckooRuntimeStats GetStats() const;

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
		data_ptr_t pointer;
	};

private:
	std::vector<Bucket> buckets;
	std::vector<Bucket> stash;
	unordered_map<hash_t, std::vector<data_ptr_t>> overflow_map;
	unordered_map<hash_t, std::vector<data_ptr_t>> victim_map;

	idx_t capacity;
	idx_t mask;
	idx_t size;
	idx_t bucket_slot_count = BUCKET_SLOT_COUNT;
	idx_t bucket_count = 0;
	idx_t bucket_mask = 0;

	double configured_load_factor = 0.5;
	idx_t configured_stash_scale = 64;
	idx_t configured_min_stash = 64;

	idx_t kickout_limit = 32;
	idx_t stash_limit = 64;
	double max_load_factor = 0.9;
	idx_t stash_scale = 64;

	idx_t total_kickouts = 0;
	idx_t rehash_count = 0;
	idx_t stash_high_watermark = 0;
	idx_t overflow_entries = 0;
	idx_t overflow_high_watermark = 0;
	idx_t cumulative_overflow_entries = 0;
	idx_t cumulative_stash_high_watermark = 0;
	idx_t max_kickout_depth = 0;
	idx_t bfs_failure_count = 0;
	idx_t recent_kickouts = 0;
	idx_t victim_entries = 0;
	idx_t victim_high_watermark = 0;
	idx_t victim_capacity = 0;
	bool victim_mode = false;
	idx_t max_rehash_attempts = 2;
	mutable uint8_t fallback_reason_mask = 0;
	mutable unordered_map<hash_t, data_ptr_t> hot_entries;
	unordered_map<hash_t, idx_t> stash_frequencies;
	unordered_map<hash_t, idx_t> collision_counts;
	idx_t duplicate_updates = 0;
 	idx_t total_insert_attempts = 0;
 	double observed_duplicate_ratio = 0.0;
 	static constexpr idx_t HOT_KEY_THRESHOLD = 8;
 	static constexpr idx_t HOT_COLLISION_THRESHOLD = 4;
 	idx_t configured_max_search_depth = 32;
	bool observed_kickout = false;
	idx_t collision_free_sequence = 0;

private:
	void Grow(idx_t new_capacity);
	void UpdateAdaptiveLimits();
	bool ShouldExpand() const;
	bool ShouldForceFallback();
	bool PromoteHotKey(hash_t hash, data_ptr_t pointer);
	enum class PlaceStatus : uint8_t { PLACED, DUPLICATE, FULL };
	void RecordDuplicate();
	void RecordKickoutDepth(idx_t depth);
	void RecordBfsFailure();
	void MaybeTuneParameters();
	PlaceStatus InsertIntoVictim(hash_t hash, data_ptr_t pointer);
	bool ShouldActivateVictimMode() const;
	auto BuildKickoutPath(hash_t hash, data_ptr_t pointer, const std::array<idx_t, NUM_HASH_FUNCTIONS> &slots)
 -> PlaceStatus;
	PlaceStatus InsertOrRehash(hash_t hash, data_ptr_t pointer, bool allow_rehash);
	PlaceStatus TryPlace(idx_t bucket_idx, hash_t hash, data_ptr_t pointer);
	PlaceStatus PushToStash(hash_t hash, data_ptr_t pointer);
	void Rehash(idx_t new_capacity);

	idx_t HashSlot(hash_t hash, idx_t function_index) const;
	idx_t FindFunctionIndex(hash_t hash, idx_t bucket_idx) const;
	void UpdateBucketGeometry();
	void UpdateVictimCapacity();
	double AdaptiveLoadFactor(idx_t count) const;
	idx_t AdaptiveStashScale(idx_t current_capacity) const;
	void PushToOverflow(hash_t hash, data_ptr_t pointer);
	void ResetCollisionCounter(hash_t hash);
	idx_t SlotBase(idx_t bucket_idx) const;
	void RelaxLoadFactor();
	bool ShouldOverflowOnFailure() const;
};

} // namespace duckdb
