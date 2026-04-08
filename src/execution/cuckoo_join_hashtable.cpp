//===----------------------------------------------------------------------===//
//                         DuckDB
//
// duckdb/execution/cuckoo_join_hashtable.cpp
//
//===----------------------------------------------------------------------===//

#include "duckdb/execution/cuckoo_join_hashtable.hpp"

#include "duckdb/common/constants.hpp"
#include "duckdb/common/helper.hpp"
#include "duckdb/common/exception.hpp"
#include <cmath>
#include <utility>

namespace duckdb {

namespace {
static inline hash_t RotateLeft64(hash_t value, uint8_t shift) {
	return (value << shift) | (value >> (64 - shift));
}

static inline hash_t Mix64(hash_t value) {
	value ^= value >> 30;
	value *= 0xbf58476d1ce4e5b9ULL;
	value ^= value >> 27;
	value *= 0x94d049bb133111ebULL;
	value ^= value >> 31;
	return value;
}

static inline hash_t DeriveHash(hash_t base, hash_t seed, uint8_t rotation) {
	hash_t mixed = base ^ seed;
	mixed += 0x9e3779b97f4a7c15ULL;
	mixed = Mix64(mixed);
	mixed = RotateLeft64(mixed, rotation);
	mixed = Mix64(mixed);
	return mixed;
}

static constexpr hash_t CUCKOO_HASH_SEEDS[3] = {0x9ddfea08eb382d69ULL, 0xc3a5c85c97cb3127ULL,
                                                0xb492b66fbe98f273ULL};
static constexpr uint8_t CUCKOO_HASH_ROT[3] = {17, 29, 41};
} // namespace

CuckooJoinHashTable::CuckooJoinHashTable(const CuckooTableConfig &config, idx_t initial_capacity)
    : capacity(0), mask(0), size(0) {
	Configure(config);
	if (initial_capacity > 0) {
		Reserve(initial_capacity);
	}
}

void CuckooJoinHashTable::Reset() {
	for (auto &bucket : buckets) {
		bucket.hash = 0;
		bucket.entry_index = DConstants::INVALID_INDEX;
	}
	stash.clear();
	size = 0;
	total_kickouts = 0;
	rehash_count = 0;
	stash_high_watermark = 0;
	overflow_map.clear();
	overflow_entries = 0;
	overflow_high_watermark = 0;
	cumulative_overflow_entries = 0;
	cumulative_stash_high_watermark = 0;
	UpdateAdaptiveLimits();
	fallback_reason_mask = CUCKOO_FALLBACK_NONE;
	hot_entries.clear();
	stash_frequencies.clear();
	collision_counts.clear();
	duplicate_updates = 0;
	total_insert_attempts = 0;
	observed_duplicate_ratio = 0.0;
}

void CuckooJoinHashTable::Configure(const CuckooTableConfig &config) {
	auto capped_target = MinValue<double>(config.target_load_factor, 0.4);
	configured_load_factor = ClampValue<double>(capped_target, 0.1, 0.4);
	max_load_factor = configured_load_factor;
	stash_scale = MaxValue<idx_t>(idx_t(1), config.stash_scale);
	configured_stash_scale = stash_scale;
	configured_min_stash = 32;
	UpdateAdaptiveLimits();
}

void CuckooJoinHashTable::Reserve(idx_t count) {
	if (count == 0) {
		return;
	}
	const auto adaptive_factor = AdaptiveLoadFactor(count);
	if (adaptive_factor != max_load_factor) {
		max_load_factor = adaptive_factor;
	}
	double slack = 1.0;
	if (count >= 1000000) {
		slack = 0.6;
	} else if (count >= 200000) {
		slack = 0.7;
	} else if (count >= 50000) {
		slack = 0.8;
	}
	auto required =
	    static_cast<uint64_t>(std::ceil(static_cast<double>(count) / (max_load_factor * slack)));
	const auto min_capacity = MaxValue<idx_t>(8, static_cast<idx_t>(NextPowerOfTwo(required)));
	if (min_capacity <= capacity) {
		return;
	}
	Rehash(min_capacity);
}

bool CuckooJoinHashTable::Insert(hash_t hash, idx_t entry_index) {
	idx_t attempts = 0;
	while (true) {
		total_insert_attempts++;
		if (ShouldExpand()) {
			idx_t grow_factor = 2;
			if (capacity > 0 && total_kickouts > capacity) {
				grow_factor = 4;
			}
			Rehash(capacity > 0 ? capacity * grow_factor : 8);
			continue;
		}
		if (ShouldForceFallback()) {
			return false;
		}
		if (capacity == 0) {
			Reserve(8);
		}
		if ((size + 1.0) > static_cast<double>(capacity) * max_load_factor) {
			Rehash(capacity * 2);
		}
		const auto status = InsertOrRehash(hash, entry_index, true);
	if (status == PlaceStatus::FULL) {
		if (++attempts > max_rehash_attempts) {
			fallback_reason_mask |= CUCKOO_FALLBACK_REHASH;
			return false;
		}
		Rehash(capacity * 2);
		continue;
	}
		if (status == PlaceStatus::PLACED) {
			size++;
		}
		stash_high_watermark = MaxValue<idx_t>(stash_high_watermark, stash.size());
		return true;
	}
}

auto CuckooJoinHashTable::InsertOrRehash(hash_t hash, idx_t entry_index, bool allow_rehash) -> PlaceStatus {
	std::array<idx_t, NUM_HASH_FUNCTIONS> slots;
	for (idx_t i = 0; i < NUM_HASH_FUNCTIONS; i++) {
		slots[i] = HashSlot(hash, i);
		auto status = TryPlace(slots[i], hash, entry_index);
		if (status != PlaceStatus::FULL) {
			return status;
		}
	}
	auto status = Kickout(slots[0], 0, hash, entry_index);
	if (status != PlaceStatus::FULL) {
		return status;
	}
	auto stash_status = PushToStash(hash, entry_index);
	if (stash_status != PlaceStatus::FULL) {
		return stash_status;
	}
	if (allow_rehash) {
		Rehash(capacity * 2);
		return InsertOrRehash(hash, entry_index, false);
	}
	return PlaceStatus::FULL;
}

auto CuckooJoinHashTable::TryPlace(idx_t slot, hash_t hash, idx_t entry_index) -> PlaceStatus {
	auto &bucket = buckets[slot];
	if (bucket.entry_index == DConstants::INVALID_INDEX) {
		bucket.hash = hash;
		bucket.entry_index = entry_index;
		ResetCollisionCounter(hash);
		return PlaceStatus::PLACED;
	}
	if (bucket.hash == hash) {
		// duplicate key: update head pointer so overflow chains remain reachable
		bucket.entry_index = entry_index;
		auto hot_entry = hot_entries.find(hash);
		if (hot_entry != hot_entries.end()) {
			hot_entry->second = entry_index;
		}
		auto &freq = stash_frequencies[hash];
		freq++;
		if (freq >= HOT_KEY_THRESHOLD) {
			hot_entries[hash] = entry_index;
		}
		RecordDuplicate();
		ResetCollisionCounter(hash);
		return PlaceStatus::DUPLICATE;
	}
	return PlaceStatus::FULL;
}

auto CuckooJoinHashTable::Kickout(idx_t slot, idx_t function_index, hash_t hash, idx_t entry_index) -> PlaceStatus {
	idx_t current_slot = slot;
	idx_t current_function = function_index;
	hash_t current_hash = hash;
	idx_t current_entry = entry_index;

	for (idx_t kick = 0; kick < kickout_limit; kick++) {
		auto &victim = buckets[current_slot];
		std::swap(current_hash, victim.hash);
		std::swap(current_entry, victim.entry_index);
		total_kickouts++;
		auto &collision = collision_counts[current_hash];
		collision++;
		if (collision >= HOT_COLLISION_THRESHOLD || kick + 1 >= kickout_limit) {
			auto status = PushToStash(current_hash, current_entry);
			if (status != PlaceStatus::PLACED) {
				return status;
			}
			return PlaceStatus::PLACED;
		}
		current_function = FindFunctionIndex(current_hash, current_slot);
		current_function = (current_function + 1) % NUM_HASH_FUNCTIONS;
		current_slot = HashSlot(current_hash, current_function);
		auto status = TryPlace(current_slot, current_hash, current_entry);
		if (status != PlaceStatus::FULL) {
			return status;
		}
	}

	return PushToStash(current_hash, current_entry);
}

auto CuckooJoinHashTable::PushToStash(hash_t hash, idx_t entry_index) -> PlaceStatus {
	if (PromoteHotKey(hash, entry_index)) {
		return PlaceStatus::PLACED;
	}
	for (auto &entry : stash) {
		if (entry.hash == hash) {
			entry.entry_index = entry_index;
			return PlaceStatus::DUPLICATE;
		}
	}
	ResetCollisionCounter(hash);
	const idx_t eager_limit = stash_limit > 0 ? MaxValue<idx_t>(idx_t(1), stash_limit / 2) : 1;
	if (stash.size() >= eager_limit) {
		PushToOverflow(hash, entry_index);
		return PlaceStatus::PLACED;
	}
	stash.push_back({hash, entry_index});
	stash_high_watermark = MaxValue<idx_t>(stash_high_watermark, stash.size());
	cumulative_stash_high_watermark = MaxValue<idx_t>(cumulative_stash_high_watermark, stash_high_watermark);
	if (stash_limit > 0 && stash.size() > stash_limit) {
		fallback_reason_mask |= CUCKOO_FALLBACK_STASH;
		stash.pop_back();
		return PlaceStatus::FULL;
	}
	return PlaceStatus::PLACED;
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
	auto old_overflow = std::move(overflow_map);
	overflow_entries = 0;
	overflow_high_watermark = MaxValue<idx_t>(overflow_high_watermark, overflow_entries);

	capacity = MaxValue<idx_t>(8, NextPowerOfTwo(new_capacity));
	mask = capacity - 1;
	buckets.clear();
	buckets.resize(capacity);
	for (auto &bucket : buckets) {
		bucket.hash = 0;
		bucket.entry_index = DConstants::INVALID_INDEX;
	}
	stash.clear();
	cumulative_stash_high_watermark = MaxValue<idx_t>(cumulative_stash_high_watermark, stash_high_watermark);
	size = 0;
	rehash_count++;
	UpdateAdaptiveLimits();
	collision_counts.clear();

	for (auto &entry : old_buckets) {
		if (entry.entry_index == DConstants::INVALID_INDEX) {
			continue;
		}
		auto status = InsertOrRehash(entry.hash, entry.entry_index, false);
		if (status == PlaceStatus::PLACED) {
			size++;
		}
	}
	for (auto &entry : old_stash) {
		if (entry.entry_index == DConstants::INVALID_INDEX) {
			continue;
		}
		auto status = InsertOrRehash(entry.hash, entry.entry_index, false);
		if (status == PlaceStatus::PLACED) {
			size++;
		}
	}
	for (auto &kv : old_overflow) {
		for (auto entry_index : kv.second) {
			auto status = InsertOrRehash(kv.first, entry_index, false);
			if (status == PlaceStatus::PLACED) {
				size++;
			} else {
				PushToOverflow(kv.first, entry_index);
			}
		}
	}
}

idx_t CuckooJoinHashTable::HashSlot(hash_t hash, idx_t function_index) const {
	if (!mask) {
		return 0;
	}
	const auto idx = function_index % NUM_HASH_FUNCTIONS;
	const auto derived = DeriveHash(hash, CUCKOO_HASH_SEEDS[idx], CUCKOO_HASH_ROT[idx]);
	return derived & mask;
}

idx_t CuckooJoinHashTable::FindFunctionIndex(hash_t hash, idx_t slot) const {
	for (idx_t i = 0; i < NUM_HASH_FUNCTIONS; i++) {
		if (HashSlot(hash, i) == slot) {
			return i;
		}
	}
	return 0;
}

double CuckooJoinHashTable::AdaptiveLoadFactor(idx_t count) const {
	double adaptive = configured_load_factor;
	if (count >= 2000000) {
		adaptive = MinValue<double>(adaptive, 0.25);
	} else if (count >= 1000000) {
		adaptive = MinValue<double>(adaptive, 0.30);
	} else if (count >= 500000) {
		adaptive = MinValue<double>(adaptive, 0.33);
	} else if (count >= 200000) {
		adaptive = MinValue<double>(adaptive, 0.35);
	}
	if (observed_duplicate_ratio > 0.15) {
		adaptive = MinValue<double>(configured_load_factor, adaptive + 0.1);
	} else if (observed_duplicate_ratio < 0.01 && count > 100000) {
		adaptive = MinValue<double>(adaptive, configured_load_factor - 0.1);
	}
	return ClampValue<double>(adaptive, 0.15, configured_load_factor);
}

idx_t CuckooJoinHashTable::AdaptiveStashScale(idx_t current_capacity) const {
	if (current_capacity == 0) {
		return configured_stash_scale;
	}
	idx_t scale = configured_stash_scale;
	if (current_capacity >= (idx_t(1) << 23)) {
		scale = MaxValue<idx_t>(idx_t(1), scale / 8);
	} else if (current_capacity >= (idx_t(1) << 21)) {
		scale = MaxValue<idx_t>(idx_t(1), scale / 4);
	} else if (current_capacity >= (idx_t(1) << 19)) {
		scale = MaxValue<idx_t>(idx_t(1), scale / 2);
	}
	return scale;
}

idx_t CuckooJoinHashTable::Lookup(hash_t hash, idx_t *results, idx_t max_results) const {
	if (capacity == 0 || !results || max_results == 0) {
		return 0;
	}
	idx_t count = 0;
	const auto append_result = [&](const Bucket &bucket) {
		if (bucket.entry_index != DConstants::INVALID_INDEX && bucket.hash == hash) {
			results[count++] = bucket.entry_index;
		}
	};
	std::array<idx_t, NUM_HASH_FUNCTIONS> unique_slots;
	idx_t slot_count = 0;
	for (idx_t i = 0; i < NUM_HASH_FUNCTIONS; i++) {
		auto slot = HashSlot(hash, i);
		bool seen = false;
		for (idx_t j = 0; j < slot_count; j++) {
			if (unique_slots[j] == slot) {
				seen = true;
				break;
			}
		}
		if (seen) {
			continue;
		}
		unique_slots[slot_count++] = slot;
		append_result(buckets[slot]);
		if (count >= max_results) {
			return count;
		}
	}
	if (count < max_results) {
		for (auto &entry : stash) {
			if (entry.hash != hash || entry.entry_index == DConstants::INVALID_INDEX) {
				continue;
			}
			results[count++] = entry.entry_index;
			if (count == max_results) {
				break;
			}
		}
	}
	if (count < max_results) {
		auto hot_entry = hot_entries.find(hash);
		if (hot_entry != hot_entries.end()) {
			results[count++] = hot_entry->second;
		}
	}
	if (count < max_results) {
		auto overflow_entry = overflow_map.find(hash);
		if (overflow_entry != overflow_map.end()) {
			for (auto entry_index : overflow_entry->second) {
				results[count++] = entry_index;
				if (count == max_results) {
					break;
				}
			}
		}
	}
	return count;
}

double CuckooJoinHashTable::LoadFactor() const {
	if (capacity == 0) {
		return 0;
	}
	return static_cast<double>(size) / static_cast<double>(capacity);
}

CuckooRuntimeStats CuckooJoinHashTable::GetStats() const {
	CuckooRuntimeStats stats;
	stats.capacity = capacity;
	stats.entries = size;
	stats.target_load_factor = max_load_factor;
	stats.stash_entries = stash.size();
	stats.stash_high_watermark = MaxValue<idx_t>(stash_high_watermark, cumulative_stash_high_watermark);
	stats.kickouts = total_kickouts;
	stats.rehashes = rehash_count;
	stats.load_factor = LoadFactor();
	stats.stash_limit = stash_limit;
	stats.kickout_limit = kickout_limit;
	stats.hash_function_count = NUM_HASH_FUNCTIONS;
	stats.fallback_reason_mask = fallback_reason_mask;
	stats.overflow_entries = cumulative_overflow_entries;
	stats.overflow_high_watermark = MaxValue<idx_t>(overflow_high_watermark, cumulative_overflow_entries);
	stats.entries += overflow_entries;
	stats.stash_entries += overflow_entries;
	stats.stash_high_watermark = MaxValue<idx_t>(stash_high_watermark, overflow_high_watermark);
	stats.fallback_reason_mask = fallback_reason_mask;
	return stats;
}

void CuckooJoinHashTable::UpdateAdaptiveLimits() {
	if (capacity == 0) {
		stash_scale = configured_stash_scale;
		stash_limit = configured_min_stash;
		kickout_limit = 32;
		return;
	}
	stash_limit = 32;
	kickout_limit = observed_duplicate_ratio > 0.10 ? idx_t(8) : idx_t(16);
}

bool CuckooJoinHashTable::ShouldExpand() const {
	if (capacity == 0) {
		return false;
	}
	const idx_t soft_limit =
	    stash_limit > 8 ? stash_limit - MaxValue<idx_t>(idx_t(4), stash_limit / 8) : stash_limit;
	if (soft_limit > 0 && stash_high_watermark >= soft_limit) {
		return true;
	}
	const idx_t kickout_threshold = MaxValue<idx_t>(capacity / 8, size);
	if (total_kickouts > kickout_threshold) {
		return true;
	}
	return false;
}

bool CuckooJoinHashTable::ShouldForceFallback() {
	if (capacity == 0) {
		return false;
	}
	uint8_t mask = fallback_reason_mask;
	const idx_t stash_soft_limit = stash_limit > 8 ? stash_limit - MaxValue<idx_t>(idx_t(4), stash_limit / 8) : stash_limit;
	const bool stash_pressure = stash_soft_limit > 0 && stash_high_watermark >= stash_soft_limit;
	if (stash_pressure) {
		mask |= CUCKOO_FALLBACK_STASH;
	}
	const bool rehash_pressure =
	    rehash_count >= max_rehash_attempts && stash_high_watermark >= MaxValue<idx_t>(idx_t(1), stash_limit / 2);
	if (rehash_pressure) {
		mask |= CUCKOO_FALLBACK_REHASH;
	}
	const idx_t kickout_threshold = MaxValue<idx_t>(capacity, size * 4);
	const bool kickout_pressure =
	    total_kickouts > kickout_threshold && stash_high_watermark >= MaxValue<idx_t>(idx_t(1), stash_limit / 2);
	if (kickout_pressure) {
		mask |= CUCKOO_FALLBACK_KICKOUT;
	}
	fallback_reason_mask = mask;
	return mask != CUCKOO_FALLBACK_NONE;
}

bool CuckooJoinHashTable::PromoteHotKey(hash_t hash, idx_t entry_index) {
	auto freq_entry = stash_frequencies.find(hash);
	if (freq_entry == stash_frequencies.end()) {
		stash_frequencies.emplace(hash, 1);
		return false;
	}
	auto &freq = freq_entry->second;
	freq++;
	if (freq >= HOT_KEY_THRESHOLD) {
		hot_entries[hash] = entry_index;
		return true;
	}
	return false;
}

void CuckooJoinHashTable::RecordDuplicate() {
	duplicate_updates++;
	if (total_insert_attempts == 0) {
		return;
	}
	observed_duplicate_ratio =
	    static_cast<double>(duplicate_updates) / static_cast<double>(total_insert_attempts + 1);
	if (observed_duplicate_ratio > 0.25 && max_load_factor > 0.7) {
		max_load_factor = 0.7;
	}
}

void CuckooJoinHashTable::PushToOverflow(hash_t hash, idx_t entry_index) {
	auto &bucket = overflow_map[hash];
	bucket.push_back(entry_index);
	overflow_entries++;
	cumulative_overflow_entries++;
	overflow_high_watermark = MaxValue<idx_t>(overflow_high_watermark, overflow_entries);
	ResetCollisionCounter(hash);
}

void CuckooJoinHashTable::ResetCollisionCounter(hash_t hash) {
	if (collision_counts.empty()) {
		return;
	}
	auto it = collision_counts.find(hash);
	if (it != collision_counts.end()) {
		collision_counts.erase(it);
	}
}
} // namespace duckdb
