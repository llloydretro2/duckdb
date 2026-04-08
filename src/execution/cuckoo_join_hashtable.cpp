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
#include <queue>
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
		bucket.pointer = nullptr;
	}
	stash.clear();
	size = 0;
	total_kickouts = 0;
	rehash_count = 0;
	stash_high_watermark = 0;
	overflow_map.clear();
	victim_map.clear();
	overflow_entries = 0;
	overflow_high_watermark = 0;
	cumulative_overflow_entries = 0;
	cumulative_stash_high_watermark = 0;
	max_kickout_depth = 0;
	bfs_failure_count = 0;
	recent_kickouts = 0;
	victim_entries = 0;
	victim_high_watermark = 0;
	victim_mode = false;
	victim_capacity = 0;
	observed_kickout = false;
	collision_free_sequence = 0;
	UpdateBucketGeometry();
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
	auto capped_target = MinValue<double>(config.target_load_factor, 0.9);
	configured_load_factor = ClampValue<double>(capped_target, 0.4, 0.9);
	max_load_factor = configured_load_factor;
	stash_scale = MaxValue<idx_t>(idx_t(1), config.stash_scale);
	configured_stash_scale = stash_scale;
	configured_min_stash = MaxValue<idx_t>(idx_t(1), config.min_stash);
	idx_t desired_slots = MaxValue<idx_t>(idx_t(1), config.bucket_slot_count);
	idx_t clamped_slots = 1;
	while (clamped_slots < desired_slots && clamped_slots < 8) {
		clamped_slots <<= 1;
	}
	bucket_slot_count = clamped_slots;
	configured_max_search_depth = MaxValue<idx_t>(idx_t(1), config.max_search_depth);
	UpdateBucketGeometry();
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

bool CuckooJoinHashTable::Insert(hash_t hash, data_ptr_t pointer) {
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
		const auto status = InsertOrRehash(hash, pointer, true);
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
			RelaxLoadFactor();
		}
		stash_high_watermark = MaxValue<idx_t>(stash_high_watermark, stash.size());
		return true;
	}
}

auto CuckooJoinHashTable::InsertOrRehash(hash_t hash, data_ptr_t pointer, bool allow_rehash) -> PlaceStatus {
	std::array<idx_t, NUM_HASH_FUNCTIONS> slots;
	for (idx_t i = 0; i < NUM_HASH_FUNCTIONS; i++) {
		slots[i] = HashSlot(hash, i);
		auto status = TryPlace(slots[i], hash, pointer);
		if (status != PlaceStatus::FULL) {
			return status;
		}
	}
	auto status = BuildKickoutPath(hash, pointer, slots);
	if (status != PlaceStatus::FULL) {
		return status;
	}
	if (ShouldActivateVictimMode()) {
		auto victim_status = InsertIntoVictim(hash, pointer);
		if (victim_status != PlaceStatus::FULL) {
			return victim_status;
		}
	}
	auto stash_status = PushToStash(hash, pointer);
	if (stash_status != PlaceStatus::FULL) {
		return stash_status;
	}
	if (ShouldOverflowOnFailure()) {
		PushToOverflow(hash, pointer);
		return PlaceStatus::PLACED;
	}
	if (allow_rehash) {
		Rehash(capacity * 2);
		return InsertOrRehash(hash, pointer, false);
	}
	return PlaceStatus::FULL;
}

auto CuckooJoinHashTable::TryPlace(idx_t slot, hash_t hash, data_ptr_t pointer) -> PlaceStatus {
	if (!mask) {
		return PlaceStatus::FULL;
	}
	const idx_t base = SlotBase(slot);
	for (idx_t offset = 0; offset < bucket_slot_count; offset++) {
		const idx_t idx = (base + offset) & mask;
		auto &bucket = buckets[idx];
		if (bucket.pointer == nullptr) {
			bucket.hash = hash;
			bucket.pointer = pointer;
			ResetCollisionCounter(hash);
			return PlaceStatus::PLACED;
		}
		if (bucket.hash == hash) {
			// duplicate key: update head pointer so overflow chains remain reachable
			bucket.pointer = pointer;
			auto hot_entry = hot_entries.find(hash);
			if (hot_entry != hot_entries.end()) {
				hot_entry->second = pointer;
			}
			auto &freq = stash_frequencies[hash];
			freq++;
			if (freq >= HOT_KEY_THRESHOLD) {
				hot_entries[hash] = pointer;
			}
			RecordDuplicate();
			ResetCollisionCounter(hash);
			return PlaceStatus::DUPLICATE;
		}
	}
	return PlaceStatus::FULL;
}

auto CuckooJoinHashTable::BuildKickoutPath(hash_t hash, data_ptr_t pointer,
                                           const std::array<idx_t, NUM_HASH_FUNCTIONS> &slots) -> PlaceStatus {
	if (!mask || capacity == 0) {
		return PlaceStatus::FULL;
	}
	struct PathNode {
		idx_t slot;
		idx_t parent;
		idx_t depth;
	};
	std::vector<PathNode> nodes;
	nodes.reserve(64);
	std::queue<idx_t> pending;
	std::vector<uint8_t> visited(capacity, 0);

	auto relocate = [&](idx_t node_idx, idx_t empty_slot) -> PlaceStatus {
		idx_t target_slot = empty_slot;
		idx_t depth = 0;
		while (node_idx != DConstants::INVALID_INDEX) {
			auto &path_node = nodes[node_idx];
			auto &source = buckets[path_node.slot];
			auto &dest = buckets[target_slot];
			dest = source;
			source.pointer = nullptr;
			source.hash = 0;
			target_slot = path_node.slot;
			node_idx = path_node.parent;
			depth++;
		}
		auto &dest = buckets[target_slot];
		dest.hash = hash;
		dest.pointer = pointer;
		RecordKickoutDepth(depth);
		ResetCollisionCounter(hash);
		return PlaceStatus::PLACED;
	};

	auto enqueue_slot = [&](idx_t slot, idx_t parent, idx_t depth) {
		if (visited[slot]) {
			return;
		}
		visited[slot] = 1;
		nodes.push_back({slot, parent, depth});
		pending.push(nodes.size() - 1);
	};

	// seed BFS with the immediate candidate blocks
	for (idx_t i = 0; i < NUM_HASH_FUNCTIONS; i++) {
		const idx_t base = slots[i];
		for (idx_t offset = 0; offset < bucket_slot_count; offset++) {
			const idx_t candidate = (base + offset) & mask;
			auto &bucket = buckets[candidate];
			if (bucket.pointer == nullptr) {
				auto &dest = buckets[candidate];
				dest.hash = hash;
				dest.pointer = pointer;
				return PlaceStatus::PLACED;
			}
			enqueue_slot(candidate, DConstants::INVALID_INDEX, 1);
		}
	}

	while (!pending.empty()) {
		const auto node_idx = pending.front();
		pending.pop();
		const auto &node = nodes[node_idx];
		if (node.depth >= configured_max_search_depth) {
			continue;
		}
		auto &victim = buckets[node.slot];
		if (victim.pointer == nullptr) {
			return relocate(node_idx, node.slot);
		}
		const idx_t current_function = FindFunctionIndex(victim.hash, node.slot);
		for (idx_t func = 0; func < NUM_HASH_FUNCTIONS; func++) {
			if (func == current_function) {
				continue;
			}
			const idx_t base = HashSlot(victim.hash, func);
			for (idx_t offset = 0; offset < bucket_slot_count; offset++) {
				const idx_t candidate = (base + offset) & mask;
				if (candidate == node.slot) {
					continue;
				}
				auto &candidate_bucket = buckets[candidate];
				if (candidate_bucket.pointer == nullptr) {
					return relocate(node_idx, candidate);
				}
				enqueue_slot(candidate, node_idx, node.depth + 1);
			}
		}
	}

	RecordBfsFailure();
	return PlaceStatus::FULL;
}

auto CuckooJoinHashTable::PushToStash(hash_t hash, data_ptr_t pointer) -> PlaceStatus {
	if (PromoteHotKey(hash, pointer)) {
		return PlaceStatus::PLACED;
	}
	for (auto &entry : stash) {
		if (entry.hash == hash) {
			entry.pointer = pointer;
			return PlaceStatus::DUPLICATE;
		}
	}
	ResetCollisionCounter(hash);
	const idx_t eager_limit = stash_limit > 0 ? MaxValue<idx_t>(idx_t(1), stash_limit / 2) : 1;
	if (stash.size() >= eager_limit) {
		PushToOverflow(hash, pointer);
		return PlaceStatus::PLACED;
	}
	stash.push_back({hash, pointer});
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
	auto old_victims = std::move(victim_map);
	overflow_entries = 0;
	overflow_high_watermark = MaxValue<idx_t>(overflow_high_watermark, overflow_entries);
	victim_entries = 0;
	victim_high_watermark = 0;
	victim_mode = false;

	capacity = MaxValue<idx_t>(8, NextPowerOfTwo(new_capacity));
	UpdateBucketGeometry();
	buckets.clear();
	buckets.resize(capacity);
	for (auto &bucket : buckets) {
		bucket.hash = 0;
		bucket.pointer = nullptr;
	}
	stash.clear();
	cumulative_stash_high_watermark = MaxValue<idx_t>(cumulative_stash_high_watermark, stash_high_watermark);
	size = 0;
	rehash_count++;
	UpdateAdaptiveLimits();
	collision_counts.clear();

	for (auto &entry : old_buckets) {
		if (entry.pointer == nullptr) {
			continue;
		}
		auto status = InsertOrRehash(entry.hash, entry.pointer, false);
		if (status == PlaceStatus::PLACED) {
			size++;
		}
	}
	for (auto &entry : old_stash) {
		if (entry.pointer == nullptr) {
			continue;
		}
		auto status = InsertOrRehash(entry.hash, entry.pointer, false);
		if (status == PlaceStatus::PLACED) {
			size++;
		}
	}
	for (auto &kv : old_overflow) {
		for (auto pointer : kv.second) {
			auto status = InsertOrRehash(kv.first, pointer, false);
			if (status == PlaceStatus::PLACED) {
				size++;
			} else {
				PushToOverflow(kv.first, pointer);
			}
		}
	}
	for (auto &kv : old_victims) {
		for (auto pointer : kv.second) {
			auto status = InsertOrRehash(kv.first, pointer, false);
			if (status == PlaceStatus::PLACED) {
				size++;
			} else {
				InsertIntoVictim(kv.first, pointer);
			}
		}
	}
}

idx_t CuckooJoinHashTable::HashSlot(hash_t hash, idx_t function_index) const {
	if (!bucket_mask) {
		return 0;
	}
	const auto idx = function_index % NUM_HASH_FUNCTIONS;
	const auto derived = DeriveHash(hash, CUCKOO_HASH_SEEDS[idx], CUCKOO_HASH_ROT[idx]);
	const auto bucket_idx = derived & bucket_mask;
	return (bucket_idx * bucket_slot_count) & mask;
}

idx_t CuckooJoinHashTable::FindFunctionIndex(hash_t hash, idx_t slot) const {
	const auto base_slot = SlotBase(slot);
	for (idx_t i = 0; i < NUM_HASH_FUNCTIONS; i++) {
		if (HashSlot(hash, i) == base_slot) {
			return i;
		}
	}
	return 0;
}

double CuckooJoinHashTable::AdaptiveLoadFactor(idx_t count) const {
	double adaptive = configured_load_factor;
	if (count >= 2000000) {
		adaptive = MinValue<double>(adaptive, 0.60);
	} else if (count >= 1000000) {
		adaptive = MinValue<double>(adaptive, 0.65);
	} else if (count >= 500000) {
		adaptive = MinValue<double>(adaptive, 0.68);
	} else if (count >= 200000) {
		adaptive = MinValue<double>(adaptive, 0.70);
	}
	if (observed_duplicate_ratio > 0.15) {
		adaptive = MinValue<double>(configured_load_factor, adaptive + 0.05);
	} else if (observed_duplicate_ratio < 0.01 && count > 100000) {
		adaptive = MinValue<double>(configured_load_factor, adaptive + 0.02);
	}
	return ClampValue<double>(adaptive, 0.5, configured_load_factor);
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

idx_t CuckooJoinHashTable::Lookup(hash_t hash, data_ptr_t *results, idx_t max_results) const {
	if (capacity == 0 || !results || max_results == 0) {
		return 0;
	}
	idx_t count = 0;
	const auto append_result = [&](const Bucket &bucket) {
		if (bucket.pointer != nullptr && bucket.hash == hash) {
			results[count++] = bucket.pointer;
		}
	};
	const auto append_bucket_range = [&](idx_t slot) {
		const idx_t base = SlotBase(slot);
		for (idx_t offset = 0; offset < bucket_slot_count && count < max_results; offset++) {
			const idx_t idx = (base + offset) & mask;
			append_result(buckets[idx]);
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
		append_bucket_range(slot);
		if (count >= max_results) {
			return count;
		}
	}
	if (count < max_results) {
		for (auto &entry : stash) {
			if (entry.hash != hash || entry.pointer == nullptr) {
				continue;
			}
			results[count++] = entry.pointer;
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
			for (auto pointer : overflow_entry->second) {
				results[count++] = pointer;
				if (count == max_results) {
					break;
				}
			}
		}
	}
	if (count < max_results) {
		auto victim_entry = victim_map.find(hash);
		if (victim_entry != victim_map.end()) {
			for (auto pointer : victim_entry->second) {
				results[count++] = pointer;
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
	stats.block_size = bucket_slot_count;
	stats.stash_entries = stash.size();
	stats.stash_high_watermark = MaxValue<idx_t>(stash_high_watermark, cumulative_stash_high_watermark);
	stats.kickouts = total_kickouts;
	stats.max_kickout_depth = max_kickout_depth;
	stats.bfs_failures = bfs_failure_count;
	stats.rehashes = rehash_count;
	stats.victim_entries = victim_entries;
	stats.victim_high_watermark = victim_high_watermark;
	stats.load_factor = LoadFactor();
	stats.stash_limit = stash_limit;
	stats.kickout_limit = kickout_limit;
	stats.hash_function_count = NUM_HASH_FUNCTIONS;
	stats.bucket_slot_count = bucket_slot_count;
	stats.fallback_reason_mask = fallback_reason_mask;
	stats.overflow_entries = cumulative_overflow_entries;
	stats.overflow_high_watermark = MaxValue<idx_t>(overflow_high_watermark, cumulative_overflow_entries);
	stats.entries += overflow_entries;
	stats.stash_entries += overflow_entries;
	stats.stash_high_watermark = MaxValue<idx_t>(stash_high_watermark, overflow_high_watermark);
	stats.fallback_reason_mask = fallback_reason_mask;
	stats.victim_mode = victim_mode;
	return stats;
}

void CuckooJoinHashTable::UpdateAdaptiveLimits() {
	stash_scale = MaxValue<idx_t>(idx_t(1), configured_stash_scale);
	if (capacity == 0) {
		stash_limit = configured_min_stash;
	} else {
		const idx_t scaled = capacity / stash_scale;
		stash_limit = MaxValue<idx_t>(configured_min_stash, scaled);
	}
	const idx_t base_kickout = observed_duplicate_ratio > 0.10 ? idx_t(8) : idx_t(32);
	kickout_limit = MinValue<idx_t>(configured_max_search_depth, base_kickout);
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
	const bool rehash_pressure = rehash_count >= max_rehash_attempts;
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

bool CuckooJoinHashTable::PromoteHotKey(hash_t hash, data_ptr_t pointer) {
	auto freq_entry = stash_frequencies.find(hash);
	if (freq_entry == stash_frequencies.end()) {
		stash_frequencies.emplace(hash, 1);
		return false;
	}
	auto &freq = freq_entry->second;
	freq++;
	if (freq >= HOT_KEY_THRESHOLD) {
		hot_entries[hash] = pointer;
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

void CuckooJoinHashTable::RecordKickoutDepth(idx_t depth) {
	if (depth == 0) {
		return;
	}
	observed_kickout = true;
	collision_free_sequence = 0;
	total_kickouts += depth;
	recent_kickouts += depth;
	max_kickout_depth = MaxValue<idx_t>(max_kickout_depth, depth);
	if (recent_kickouts >= MaxValue<idx_t>(idx_t(64), capacity / 8)) {
		MaybeTuneParameters();
		recent_kickouts = 0;
	}
}

void CuckooJoinHashTable::RecordBfsFailure() {
	observed_kickout = true;
	collision_free_sequence = 0;
	bfs_failure_count++;
	if (bfs_failure_count % 4 == 0 && max_load_factor > 0.35) {
		max_load_factor = MaxValue<double>(0.35, max_load_factor - 0.05);
	}
	if (!victim_mode && ShouldActivateVictimMode()) {
		victim_mode = true;
	}
}

void CuckooJoinHashTable::MaybeTuneParameters() {
	const double current_load = LoadFactor();
	if (current_load > max_load_factor * 0.95 && max_load_factor > 0.35) {
		max_load_factor = MaxValue<double>(0.35, max_load_factor - 0.03);
	} else if (current_load < configured_load_factor * 0.5 && max_load_factor < configured_load_factor) {
		max_load_factor = MinValue<double>(configured_load_factor, max_load_factor + 0.02);
	}
	if (max_kickout_depth >= configured_max_search_depth - 4 && configured_max_search_depth < 256) {
		configured_max_search_depth = MinValue<idx_t>(idx_t(256), configured_max_search_depth + 8);
	} else if (max_kickout_depth < configured_max_search_depth / 4 && configured_max_search_depth > 32) {
		configured_max_search_depth = MaxValue<idx_t>(idx_t(32), configured_max_search_depth - 4);
	}
}

auto CuckooJoinHashTable::InsertIntoVictim(hash_t hash, data_ptr_t pointer) -> PlaceStatus {
	if (victim_capacity == 0 && capacity == 0) {
		return PlaceStatus::FULL;
	}
	victim_mode = true;
	auto &bucket = victim_map[hash];
	bucket.push_back(pointer);
	victim_entries++;
	victim_high_watermark = MaxValue<idx_t>(victim_high_watermark, victim_entries);
	ResetCollisionCounter(hash);
	if (victim_entries > victim_capacity && victim_capacity > 0) {
		fallback_reason_mask |= CUCKOO_FALLBACK_KICKOUT;
		return PlaceStatus::FULL;
	}
	return PlaceStatus::PLACED;
}

bool CuckooJoinHashTable::ShouldActivateVictimMode() const {
	if (victim_capacity == 0) {
		return false;
	}
	if (victim_mode) {
		return true;
	}
	const idx_t failure_threshold = 4;
	if (bfs_failure_count >= failure_threshold) {
		return true;
	}
	return false;
}

void CuckooJoinHashTable::PushToOverflow(hash_t hash, data_ptr_t pointer) {
	auto &bucket = overflow_map[hash];
	bucket.push_back(pointer);
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

idx_t CuckooJoinHashTable::SlotBase(idx_t bucket_idx) const {
	if (!mask) {
		return 0;
	}
	idx_t idx = bucket_idx & mask;
	if (bucket_slot_count <= 1) {
		return idx;
	}
	return idx - (idx % bucket_slot_count);
}

void CuckooJoinHashTable::UpdateBucketGeometry() {
	if (bucket_slot_count == 0) {
		bucket_slot_count = 1;
	}
	if (capacity == 0) {
		bucket_count = 0;
		bucket_mask = 0;
		mask = 0;
		return;
	}
	if (capacity < bucket_slot_count) {
		capacity = bucket_slot_count;
	}
	while (capacity % bucket_slot_count != 0) {
		capacity <<= 1;
	}
	mask = capacity - 1;
	bucket_count = capacity / bucket_slot_count;
	bucket_mask = bucket_count > 0 ? bucket_count - 1 : 0;
	UpdateVictimCapacity();
}

void CuckooJoinHashTable::UpdateVictimCapacity() {
	if (capacity == 0) {
		victim_capacity = 0;
		return;
	}
	victim_capacity = MaxValue<idx_t>(capacity / 4, idx_t(1024));
	if (victim_entries > victim_capacity) {
		victim_mode = true;
	}
}

void CuckooJoinHashTable::RelaxLoadFactor() {
	if (observed_kickout) {
		collision_free_sequence = 0;
		return;
	}
	collision_free_sequence++;
	if (collision_free_sequence >= 2048 && max_load_factor < configured_load_factor) {
		max_load_factor = MinValue<double>(configured_load_factor, max_load_factor + 0.05);
		collision_free_sequence = 0;
	}
}

bool CuckooJoinHashTable::ShouldOverflowOnFailure() const {
	if (capacity == 0) {
		return true;
	}
	const idx_t kickout_threshold = MaxValue<idx_t>(idx_t(16), capacity / 256);
	if (total_kickouts > kickout_threshold) {
		return true;
	}
	const idx_t overflow_limit = MaxValue<idx_t>(capacity / 8, idx_t(2048));
	if (overflow_entries >= overflow_limit) {
		return false;
	}
	if (rehash_count >= max_rehash_attempts && size >= capacity / 8) {
		return true;
	}
	return false;
}

} // namespace duckdb
