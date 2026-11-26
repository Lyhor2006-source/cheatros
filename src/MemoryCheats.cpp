#include "MemoryCheats.h"
#include "MachMemory.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

namespace MemoryCheats {

namespace {

constexpr size_t kFeatureCount = static_cast<size_t>(IosUIBridge::MemoryFeature::Count);

struct FeatureRuntimeState {
    bool enabled = false;
    bool pending = false;
    bool error = false;
    bool active = false;
    std::string detail;
    MachMemory::PatchState patches;
    std::vector<uintptr_t> freezeAddrs;
    float param = 1.0f;
};

struct WorkerTask {
    IosUIBridge::MemoryFeature feature;
    bool enable;
    float param;
};

std::mutex gStateMutex;
FeatureRuntimeState gFeatures[kFeatureCount];
std::atomic<bool> gFlyEnabled{false};
std::atomic<bool> gUndergroundEnabled{false};
std::atomic<float> gSpeedMultiplier{1.1f};
MachMemory::PatchState gFlyPatches;
MachMemory::PatchState gUndergroundPatches;
std::mutex gFlyMutex;
std::mutex gUndergroundMutex;

std::mutex gWorkerMutex;
std::condition_variable gWorkerCv;
std::deque<WorkerTask> gTaskQueue;
std::thread gWorkerThread;
bool gWorkerRunning = false;
bool gInitialized = false;

std::vector<MachMemory::MemoryRegion> QueryPreferredRegions(MachMemory::RegionMode fallbackMode) {
    auto regions = MachMemory::QueryAllWritableRegions();
    if (regions.empty()) {
        regions = MachMemory::QueryRegions(fallbackMode);
    }
    return regions;
}

void SetResultLocked(
    IosUIBridge::MemoryFeature feature,
    bool enabled,
    bool active,
    bool error,
    const std::string& detail) {
    auto& st = gFeatures[static_cast<size_t>(feature)];
    st.enabled = enabled;
    st.pending = false;
    st.active = active;
    st.error = error;
    st.detail = detail;
}

size_t ApplyDwordToTargets(
    MachMemory::PatchState& patchState,
    const std::vector<uintptr_t>& addrs,
    uint32_t value) {
    size_t applied = 0;
    for (uintptr_t addr : addrs) {
        if (patchState.AddAndApply(addr, &value, sizeof(value))) {
            ++applied;
        }
    }
    return applied;
}

size_t ApplyFloatToTargets(
    MachMemory::PatchState& patchState,
    const std::vector<uintptr_t>& addrs,
    float value) {
    size_t applied = 0;
    for (uintptr_t addr : addrs) {
        if (patchState.AddAndApply(addr, &value, sizeof(value))) {
            ++applied;
        }
    }
    return applied;
}

size_t ApplyDoubleToTargets(
    MachMemory::PatchState& patchState,
    const std::vector<uintptr_t>& addrs,
    double value) {
    size_t applied = 0;
    for (uintptr_t addr : addrs) {
        if (patchState.AddAndApply(addr, &value, sizeof(value))) {
            ++applied;
        }
    }
    return applied;
}

// Specific scanners decoded from verified binary patterns
std::vector<uintptr_t> ScanWallV1Addrs() {
    auto regions = QueryPreferredRegions(MachMemory::GetRegionMode());
    auto hits = MachMemory::ScanDword(regions, 0x3089705fU, 32);
    if (!hits.empty()) {
        return hits;
    }

    // Fallback group only over strict heap regions with tight match cap to prevent false positives
    auto heapOnly = MachMemory::QueryRegions(MachMemory::RegionMode::WritableOnly);
    const std::vector<MachMemory::SearchItem> grp = {
        MachMemory::SearchItem::Dword(69),
        MachMemory::SearchItem::Dword(3),
        MachMemory::SearchItem::Dword(4),
    };
    hits = MachMemory::GroupScan(heapOnly, grp, 1, 24, 16, true);
    if (hits.size() > 8) {
        hits.clear();
    }
    return hits;
}

std::vector<uintptr_t> ScanNoGrassAddrs() {
    auto regions = QueryPreferredRegions(MachMemory::GetRegionMode());
    std::vector<uintptr_t> hits;
    std::vector<uint8_t> buf(65536 + 1024);

    for (const auto& reg : regions) {
        for (uintptr_t cur = reg.start; cur < reg.end; cur += 65536) {
            const size_t chunk = static_cast<size_t>(std::min<uintptr_t>(65536 + 512, reg.end - cur));
            const size_t limit = static_cast<size_t>(std::min<uintptr_t>(65536, reg.end - cur));
            if (chunk < 4 || !MachMemory::ReadMemory(cur, buf.data(), chunk)) continue;

            for (size_t off = 0; off < limit; off += 4) {
                uint32_t v = 0;
                std::memcpy(&v, buf.data() + off, 4);
                if (v != 5122U) continue;
                const size_t winStart = (off > 512) ? (off - 512) : 0;
                const size_t winEnd = std::min(chunk, off + 512);
                bool neighborOk = false;
                for (size_t scan = winStart; scan + 4 <= winEnd; scan += 4) {
                    if (scan == off) continue;
                    int32_t nv = 0;
                    std::memcpy(&nv, buf.data() + scan, 4);
                    if (nv == 5120 || nv == 5121 || nv == 5123) {
                        neighborOk = true;
                        break;
                    }
                }
                if (neighborOk) {
                    hits.push_back(cur + off);
                    if (hits.size() >= 32) return hits;
                }
            }
        }
    }

    if (hits.empty()) {
        auto heapRegs = MachMemory::QueryRegions(MachMemory::RegionMode::WritableOnly);
        hits = MachMemory::ProximityScan(
            heapRegs,
            MachMemory::SearchItem::Dword(1),
            MachMemory::SearchItem::Dword(5122),
            512,
            17);
        if (hits.size() > 16) {
            hits.clear();
        }
    }
    return hits;
}

// ---------------------------------------------------------------------------
// Auto-Reload ammo watcher — real-reload state machine
//
// Per-slot states:
//   IDLE     – mag > 0, just monitoring, do nothing
//   EMPTY    – mag just hit 0; game reload animation is now running naturally;
//              we do NOT touch memory here — let the game play the animation
//   REFILLED – game itself wrote a >0 value back (reload complete);
//              we override with maxMag so the player gets a full magazine;
//              then enter a short cooldown before returning to IDLE
//
// The result: reload animation runs at the game's own speed and visuals,
// but the final ammo count is always maxMag instead of reserve-limited.
// ---------------------------------------------------------------------------
enum class AmmoState : uint8_t {
    Idle     = 0,
    Empty    = 1,
    Refilled = 2,   // game wrote >0 after reload; we override then wait cooldown
};

struct AmmoEntry {
    uintptr_t addr;
    uint32_t  maxMag;
    AmmoState state    = AmmoState::Idle;
    uint32_t  cooldown = 0;   // ticks remaining before re-arming after a write
};
std::mutex               gAutoReloadMutex;
std::vector<AmmoEntry>   gAutoReloadEntries;
std::atomic<bool>        gAutoReloadEnabled{false};

// Scan for active magazine dwords.
// PUBG Mobile stores per-weapon ammo as a dword with value in [1..200].
// We look for dwords whose value is in a "live ammo" band and are surrounded
// by neighbours that look like weapon-slot fields (ammo totals, weapon IDs).
// The scanner intentionally stays conservative: at most 32 hits, and each
// hit must have at least one plausible neighbour in [1..999] within 128 bytes.
std::vector<std::pair<uintptr_t,uint32_t>> ScanAmmoEntries() {
    auto regions = QueryPreferredRegions(MachMemory::GetRegionMode());
    std::vector<std::pair<uintptr_t,uint32_t>> results;
    std::vector<uint8_t> buf(65536 + 256);

    for (const auto& reg : regions) {
        for (uintptr_t cur = reg.start; cur < reg.end; cur += 65536) {
            const size_t chunk = static_cast<size_t>(
                std::min<uintptr_t>(65536 + 192, reg.end - cur));
            const size_t limit = static_cast<size_t>(
                std::min<uintptr_t>(65536, reg.end - cur));
            if (chunk < 8 || !MachMemory::ReadMemory(cur, buf.data(), chunk)) continue;

            for (size_t off = 0; off < limit; off += 4) {
                uint32_t v = 0;
                std::memcpy(&v, buf.data() + off, 4);
                // Plausible magazine capacities: 5..200 (pistol to LMG)
                if (v < 5 || v > 200) continue;

                // Need at least one neighbour in [1..999] within 128 bytes
                // AND one neighbour that equals v (reserve/total ammo slot)
                const size_t winS = (off > 128) ? (off - 128) : 0;
                const size_t winE = std::min(chunk - 4, off + 128);
                bool hasReserve = false;
                bool hasTotal   = false;
                for (size_t s = winS; s <= winE; s += 4) {
                    if (s == off) continue;
                    uint32_t nv = 0;
                    std::memcpy(&nv, buf.data() + s, 4);
                    if (nv >= 1 && nv <= 999)  hasReserve = true;
                    if (nv == v)               hasTotal   = true;
                }
                if (hasReserve && hasTotal) {
                    results.emplace_back(cur + off, v);
                    if (results.size() >= 32) return results;
                }
            }
        }
    }
    return results;
}

std::vector<uintptr_t> ScanFastParachuteAddrs() {
    auto regions = QueryPreferredRegions(MachMemory::GetRegionMode());
    std::vector<uintptr_t> hits;
    std::vector<uint8_t> buf(65536 + 256);

    for (const auto& reg : regions) {
        for (uintptr_t cur = reg.start; cur < reg.end; cur += 65536) {
            const size_t chunk = static_cast<size_t>(std::min<uintptr_t>(65536 + 128, reg.end - cur));
            const size_t limit = static_cast<size_t>(std::min<uintptr_t>(65536, reg.end - cur));
            if (chunk < 4 || !MachMemory::ReadMemory(cur, buf.data(), chunk)) continue;

            for (size_t off = 0; off < limit; off += 4) {
                uint32_t v = 0;
                std::memcpy(&v, buf.data() + off, 4);
                if (v != 2000U) continue;
                const size_t winStart = (off > 100) ? (off - 100) : 0;
                const size_t winEnd = std::min(chunk, off + 100);
                bool neighborOk = false;
                for (size_t scan = winStart; scan + 4 <= winEnd; scan += 4) {
                    if (scan == off) continue;
                    uint32_t nv = 0;
                    std::memcpy(&nv, buf.data() + scan, 4);
                    if ((nv & ~1U) == 118U || nv == 0xa000U) {
                        neighborOk = true;
                        break;
                    }
                }
                if (neighborOk) {
                    hits.push_back(cur + off);
                    if (hits.size() >= 32) return hits;
                }
            }
        }
    }
    return hits;
}

std::vector<uintptr_t> ScanClearFogAddrs() {
    auto regions = QueryPreferredRegions(MachMemory::GetRegionMode());
    std::vector<uintptr_t> hits;
    std::vector<uint8_t> buf(65536 + 256);

    for (const auto& reg : regions) {
        for (uintptr_t cur = reg.start; cur < reg.end; cur += 65536) {
            const size_t chunk = static_cast<size_t>(std::min<uintptr_t>(65536 + 128, reg.end - cur));
            const size_t limit = static_cast<size_t>(std::min<uintptr_t>(65536, reg.end - cur));
            if (chunk < 16 || !MachMemory::ReadMemory(cur, buf.data(), chunk)) continue;

            for (size_t off = 0; off < limit && off + 16 <= chunk; off += 4) {
                float f[4] = {};
                std::memcpy(f, buf.data() + off, sizeof(f));
                if (std::fabs(f[0] - 2.5f) >= 0.01f ||
                    std::fabs(f[1] - 2.5f) >= 0.01f ||
                    std::fabs(f[2] - 2.5f) >= 0.01f ||
                    std::fabs(f[3] - 2.5f) >= 0.01f) {
                    continue;
                }
                const size_t winStart = (off > 100) ? (off - 100) : 0;
                const size_t winEnd = std::min(chunk, off + 100);
                bool neighborOk = false;
                for (size_t scan = winStart; scan + 4 <= winEnd; scan += 4) {
                    float nv = 0.0f;
                    std::memcpy(&nv, buf.data() + scan, 4);
                    if (std::fabs(nv - (-1.0f)) < 0.01f || std::fabs(nv - (-200.0f)) < 1.0f) {
                        neighborOk = true;
                        break;
                    }
                }
                if (neighborOk) {
                    hits.push_back(cur + off + 12);
                    if (hits.size() >= 64) return hits;
                }
            }
        }
    }
    return hits;
}

std::vector<uintptr_t> ScanFastShotAddrs() {
    auto regions = QueryPreferredRegions(MachMemory::GetRegionMode());
    std::vector<uintptr_t> hits;
    std::vector<uint8_t> buf(65536 + 64);

    for (const auto& reg : regions) {
        for (uintptr_t cur = reg.start; cur < reg.end; cur += 65536) {
            const size_t chunk = static_cast<size_t>(std::min<uintptr_t>(65536 + 32, reg.end - cur));
            const size_t limit = static_cast<size_t>(std::min<uintptr_t>(65536, reg.end - cur));
            if (chunk < 24 || !MachMemory::ReadMemory(cur, buf.data(), chunk)) continue;

            for (size_t off = 0; off < limit && off + 24 <= chunk; off += 4) {
                float f = 0.0f;
                std::memcpy(&f, buf.data() + off, sizeof(f));
                const bool matchVal = (std::fabs(f - 1.0f) < 0.001f) || (std::fabs(f - (-46.0f)) < 0.1f);
                if (!matchVal) continue;
                for (size_t delta = 4; delta <= 20; delta += 4) {
                    uint32_t tag = 0;
                    std::memcpy(&tag, buf.data() + off + delta, sizeof(tag));
                    if (tag == 0x7263730cU) {
                        hits.push_back(cur + off);
                        if (hits.size() >= 64) return hits;
                        break;
                    }
                }
            }
        }
    }
    return hits;
}

std::vector<uintptr_t> ScanCameraWideDoubles() {
    auto regions = QueryPreferredRegions(MachMemory::GetRegionMode());
    auto hits = MachMemory::GroupScan(
        regions,
        {
            MachMemory::SearchItem::Double(5.3),
            MachMemory::SearchItem::Double(60.0),
            MachMemory::SearchItem::Double(45.0),
        },
        2,
        512,
        64,
        false);
    if (!hits.empty()) return hits;

    // Fallback: 45.0 double near 5.3 or 58.0
    std::vector<uint8_t> buf(65536 + 512);
    for (const auto& reg : regions) {
        for (uintptr_t cur = reg.start; cur < reg.end; cur += 65536) {
            const size_t chunk = static_cast<size_t>(std::min<uintptr_t>(65536 + 512, reg.end - cur));
            const size_t limit = static_cast<size_t>(std::min<uintptr_t>(65536, reg.end - cur));
            if (chunk < 8 || !MachMemory::ReadMemory(cur, buf.data(), chunk)) continue;

            for (size_t off = 0; off < limit && off + 8 <= chunk; off += 8) {
                double d = 0.0;
                std::memcpy(&d, buf.data() + off, sizeof(d));
                if (std::fabs(d - 45.0) >= 0.01) continue;
                const size_t winStart = (off > 512) ? (off - 512) : 0;
                const size_t winEnd = std::min(chunk, off + 512);
                bool has53 = false;
                bool has58 = false;
                for (size_t scan = winStart; scan + 8 <= winEnd; scan += 8) {
                    if (scan == off) continue;
                    double nd = 0.0;
                    std::memcpy(&nd, buf.data() + scan, 8);
                    if (std::fabs(nd - 5.3) < 0.01) has53 = true;
                    if (std::fabs(nd - 58.0) < 0.01) has58 = true;
                }
                if (has53 && has58) {
                    hits.push_back(cur + off);
                    if (hits.size() >= 64) return hits;
                }
            }
        }
    }
    return hits;
}

void ExecuteTask(const WorkerTask& task) {
    using MF = IosUIBridge::MemoryFeature;
    const size_t idx = static_cast<size_t>(task.feature);

    if (!task.enable) {
        size_t rem = 0;
        MachMemory::PatchState toRestore;
        {
            std::lock_guard<std::mutex> lock(gStateMutex);
            toRestore = std::move(gFeatures[idx].patches);
            gFeatures[idx].freezeAddrs.clear();
        }
        toRestore.RestoreAll(&rem);
        std::lock_guard<std::mutex> lock(gStateMutex);
        if (rem == 0) {
            SetResultLocked(task.feature, false, false, false, "OFF");
        } else {
            gFeatures[idx].patches = std::move(toRestore);
            SetResultLocked(task.feature, false, false, true, "Restore pending: memory changed or inaccessible");
        }
        return;
    }

    // Features driven purely via Python runtime / BigWorld hooks
    if (task.feature == MF::WallV2 ||
        task.feature == MF::SuperJump ||
        task.feature == MF::ZeroGravity) {
        std::lock_guard<std::mutex> lock(gStateMutex);
        SetResultLocked(task.feature, true, true, false, "ACTIVE (BigWorld)");
        return;
    }

    // Auto-Reload: arms the watcher; no memory patch needed
    if (task.feature == MF::AutoReload) {
        if (task.enable) {
            auto entries = ScanAmmoEntries();
            std::lock_guard<std::mutex> lk(gAutoReloadMutex);
            gAutoReloadEntries.clear();
            for (const auto& e : entries) {
                gAutoReloadEntries.push_back(AmmoEntry{e.first, e.second});
            }
            gAutoReloadEnabled.store(true, std::memory_order_relaxed);
            std::lock_guard<std::mutex> stLock(gStateMutex);
            char buf[64];
            const size_t cnt = gAutoReloadEntries.size();
            if (cnt > 0) {
                std::snprintf(buf, sizeof(buf), "ACTIVE (%zu slots)", cnt);
                SetResultLocked(task.feature, true, true, false, buf);
            } else {
                SetResultLocked(task.feature, false, false, true,
                    "No ammo slots found (enter match first)");
            }
        } else {
            gAutoReloadEnabled.store(false, std::memory_order_relaxed);
            {
                std::lock_guard<std::mutex> lk(gAutoReloadMutex);
                gAutoReloadEntries.clear();
            }
            std::lock_guard<std::mutex> stLock(gStateMutex);
            SetResultLocked(task.feature, false, false, false, "OFF");
        }
        return;
    }

    // Features requiring external server-leased scripts (not bundled)
    if (task.feature == MF::FastParachuteV2 ||
        task.feature == MF::GhostDesync ||
        task.feature == MF::GhostVisual ||
        task.feature == MF::SpiderClimb ||
        task.feature == MF::MagicBullet ||
        task.feature == MF::WaterWalk ||
        task.feature == MF::InfiniteBreath ||
        task.feature == MF::AntiCheatShield ||
        task.feature == MF::ClearWater ||
        task.feature == MF::RemovedFeature) {
        std::lock_guard<std::mutex> lock(gStateMutex);
        SetResultLocked(task.feature, false, false, true, "Not bundled (requires server script)");
        return;
    }

    auto regions = QueryPreferredRegions(MachMemory::GetRegionMode());
    if (regions.empty()) {
        std::lock_guard<std::mutex> lock(gStateMutex);
        SetResultLocked(task.feature, false, false, true, "No eligible writable memory regions");
        return;
    }

    MachMemory::PatchState newPatches;
    std::vector<uintptr_t> newFreezeAddrs;
    size_t matched = 0;
    size_t applied = 0;
    std::string detail;

    switch (task.feature) {
        case MF::AkmOneHit: {
            auto hits = MachMemory::GroupScan(
                regions,
                {MachMemory::SearchItem::Dword(99103),
                 MachMemory::SearchItem::Dword(112775),
                 MachMemory::SearchItem::Dword(20002),
                 MachMemory::SearchItem::Dword(112774)},
                2, 97, 64, true);
            matched = hits.size();
            applied = ApplyDwordToTargets(newPatches, hits, 20005U);
            break;
        }
        case MF::M4a1OneHit: {
            auto hits = MachMemory::GroupScan(
                regions,
                {MachMemory::SearchItem::Dword(20108),
                 MachMemory::SearchItem::Dword(20001)},
                1, 512, 64, true);
            matched = hits.size();
            applied = ApplyDwordToTargets(newPatches, hits, 20005U);
            break;
        }
        case MF::P90OneHit: {
            auto hits = MachMemory::GroupScan(
                regions,
                {MachMemory::SearchItem::Dword(20018),
                 MachMemory::SearchItem::Dword(201014),
                 MachMemory::SearchItem::Dword(49)},
                0, 512, 64, true);
            matched = hits.size();
            applied = ApplyDwordToTargets(newPatches, hits, 20004U);
            break;
        }
        case MF::QbzOneHit: {
            auto hits = MachMemory::GroupScan(
                regions,
                {MachMemory::SearchItem::Dword(20042),
                 MachMemory::SearchItem::Dword(1111147),
                 MachMemory::SearchItem::Dword(25)},
                0, 512, 64, true);
            matched = hits.size();
            applied = ApplyDwordToTargets(newPatches, hits, 20004U);
            break;
        }
        case MF::Pp19OneHit: {
            auto hits = MachMemory::GroupScan(
                regions,
                {MachMemory::SearchItem::Dword(20017),
                 MachMemory::SearchItem::Dword(1111245)},
                0, 512, 64, true);
            matched = hits.size();
            applied = ApplyDwordToTargets(newPatches, hits, 20004U);
            break;
        }
        case MF::Mp5OneHit: {
            auto hits = MachMemory::GroupScan(
                regions,
                {MachMemory::SearchItem::Dword(20012),
                 MachMemory::SearchItem::Dword(21006)},
                0, 512, 64, true);
            matched = hits.size();
            applied = ApplyDwordToTargets(newPatches, hits, 20004U);
            break;
        }
        case MF::VectorOneHit: {
            auto hits = MachMemory::GroupScan(
                regions,
                {MachMemory::SearchItem::Dword(20025),
                 MachMemory::SearchItem::Dword(90037)},
                0, 512, 64, true);
            matched = hits.size();
            applied = ApplyDwordToTargets(newPatches, hits, 20004U);
            break;
        }
        case MF::OneHitAllGun: {
            const std::vector<std::vector<MachMemory::SearchItem>> groups = {
                {MachMemory::SearchItem::Dword(20018), MachMemory::SearchItem::Dword(201014), MachMemory::SearchItem::Dword(49)},
                {MachMemory::SearchItem::Dword(20042), MachMemory::SearchItem::Dword(1111147), MachMemory::SearchItem::Dword(25)},
                {MachMemory::SearchItem::Dword(20012), MachMemory::SearchItem::Dword(21006)},
                {MachMemory::SearchItem::Dword(20025), MachMemory::SearchItem::Dword(90037)},
                {MachMemory::SearchItem::Dword(20017), MachMemory::SearchItem::Dword(1111245)},
            };
            for (const auto& g : groups) {
                auto hits = MachMemory::GroupScan(regions, g, 0, 512, 64, true);
                matched += hits.size();
                applied += ApplyDwordToTargets(newPatches, hits, 20004U);
            }
            break;
        }
        case MF::DesertEagleRpg: {
            auto hits = MachMemory::GroupScan(
                regions,
                {MachMemory::SearchItem::Dword(121114),
                 MachMemory::SearchItem::Dword(20015)},
                1, 512, 64, true);
            if (hits.empty()) {
                hits = MachMemory::GroupScan(
                    regions,
                    {MachMemory::SearchItem::Dword(82717),
                     MachMemory::SearchItem::Dword(20015)},
                    1, 512, 64, true);
            }
            matched = hits.size();
            applied = ApplyDwordToTargets(newPatches, hits, 20031U);
            break;
        }
        case MF::G18cRpg: {
            auto hits = MachMemory::GroupScan(
                regions,
                {MachMemory::SearchItem::Dword(20014),
                 MachMemory::SearchItem::Dword(111753)},
                0, 512, 64, true);
            matched = hits.size();
            applied = ApplyDwordToTargets(newPatches, hits, 20031U);
            break;
        }
        case MF::AkmRpg: {
            auto hits = MachMemory::GroupScan(
                regions,
                {MachMemory::SearchItem::Dword(99103),
                 MachMemory::SearchItem::Dword(112775),
                 MachMemory::SearchItem::Dword(20002),
                 MachMemory::SearchItem::Dword(112774)},
                2, 512, 64, true);
            matched = hits.size();
            applied = ApplyDwordToTargets(newPatches, hits, 20031U);
            break;
        }
        case MF::NoRecoil: {
            auto hits = MachMemory::ProximityScan(
                regions,
                MachMemory::SearchItem::Double(30000000.0),
                MachMemory::SearchItem::Double(1.0),
                512, 10);
            if (hits.empty()) {
                hits = MachMemory::GroupScan(
                    regions,
                    {MachMemory::SearchItem::Double(1.0),
                     MachMemory::SearchItem::Double(30000000.0)},
                    0, 512, 10, false);
            }
            matched = hits.size();
            applied = ApplyDoubleToTargets(newPatches, hits, 0.0);
            break;
        }
        case MF::AutoScope: {
            auto hits = MachMemory::GroupScan(
                regions,
                {MachMemory::SearchItem::Dword(1280),
                 MachMemory::SearchItem::Dword(20053)},
                0, 512, 64, true);
            matched = hits.size();
            applied = ApplyDwordToTargets(newPatches, hits, 1274U);
            break;
        }
        case MF::HighScope: {
            auto hits = MachMemory::GroupScan(
                regions,
                {MachMemory::SearchItem::Double(19.4),
                 MachMemory::SearchItem::Float(1.945f)},
                0, 512, 64, true);
            matched = hits.size();
            applied = ApplyDoubleToTargets(newPatches, hits, 95.0);
            break;
        }
        case MF::FastShot: {
            auto hits = ScanFastShotAddrs();
            matched = hits.size();
            applied = ApplyFloatToTargets(newPatches, hits, 100.0f);
            newFreezeAddrs = std::move(hits);
            break;
        }
        case MF::FastReload: {
            auto hits = MachMemory::GroupScan(
                regions,
                {MachMemory::SearchItem::Double(10.1),
                 MachMemory::SearchItem::Double(1.0)},
                1, 512, 16, true);
            if (hits.size() <= 16) {
                matched = hits.size();
                applied = ApplyDoubleToTargets(newPatches, hits, 4.2);
            }
            break;
        }
        case MF::FastHeal: {
            // Only patch the Double duration slots {0, 1, 3}; never overwrite 4-byte Dword(12) with 8-byte Double
            auto hits = MachMemory::GroupScanMany(
                regions,
                {MachMemory::SearchItem::Double(8.0),
                 MachMemory::SearchItem::Double(6.0),
                 MachMemory::SearchItem::Dword(12),
                 MachMemory::SearchItem::Double(4.0)},
                {0, 1, 3},
                512, 16, true);
            matched = hits.size();
            applied = ApplyDoubleToTargets(newPatches, hits, 0.1);
            break;
        }
        case MF::SpeedHack: {
            const float mult = std::clamp(task.param, 1.1f, 50.0f);
            gSpeedMultiplier.store(mult, std::memory_order_relaxed);
            auto hits = MachMemory::GroupScan(
                regions,
                {MachMemory::SearchItem::Double(3.05),
                 MachMemory::SearchItem::Double(34.0),
                 MachMemory::SearchItem::Double(1.1),
                 MachMemory::SearchItem::Double(-2000.0)},
                2, 512, 16, true);
            matched = hits.size();
            applied = ApplyDoubleToTargets(newPatches, hits, static_cast<double>(mult));
            char buf[64];
            std::snprintf(buf, sizeof(buf), "ACTIVE (%.1fx)", mult);
            detail = buf;
            break;
        }
        case MF::WallV1: {
            auto hits = ScanWallV1Addrs();
            matched = hits.size();
            for (uintptr_t addr : hits) {
                uint32_t curVal = 0;
                uint32_t patchVal = 4U;
                if (MachMemory::ReadValue(addr, &curVal) && curVal == 0x3089705fU) {
                    patchVal = 0x7f7fc99eU;
                }
                if (newPatches.AddAndApply(addr, &patchVal, sizeof(patchVal))) {
                    ++applied;
                }
            }
            break;
        }
        case MF::NoFallDamage: {
            auto hits = MachMemory::GroupScan(
                regions,
                {MachMemory::SearchItem::FloatBits(0xbf7dU),
                 MachMemory::SearchItem::Float(450.0f)},
                1, 512, 16, true);
            matched = hits.size();
            applied = ApplyFloatToTargets(newPatches, hits, 180.0f);
            newFreezeAddrs = std::move(hits);
            break;
        }
        case MF::NoGrass: {
            auto hits = ScanNoGrassAddrs();
            matched = hits.size();
            applied = ApplyDwordToTargets(newPatches, hits, 0U);
            break;
        }
        case MF::FastParachute: {
            auto hits = ScanFastParachuteAddrs();
            matched = hits.size();
            applied = ApplyDwordToTargets(newPatches, hits, 60U);
            break;
        }
        case MF::IpadView: {
            auto hits = ScanCameraWideDoubles();
            matched = hits.size();
            applied = ApplyDoubleToTargets(newPatches, hits, 68.0);
            break;
        }
        case MF::ClearFog: {
            auto hits = ScanClearFogAddrs();
            matched = hits.size();
            applied = ApplyFloatToTargets(newPatches, hits, 0.0f);
            break;
        }
        default:
            break;
    }

    // Some features also mirror into BigWorld Python runtime (`_pb_movement_world`)
    const bool hasPythonFallback =
        (task.feature == MF::SpeedHack ||
         task.feature == MF::WallV1 ||
         task.feature == MF::NoFallDamage ||
         task.feature == MF::NoGrass ||
         task.feature == MF::FastParachute ||
         task.feature == MF::IpadView ||
         task.feature == MF::ClearFog ||
         task.feature == MF::NoRecoil);

    std::lock_guard<std::mutex> lock(gStateMutex);
    auto& st = gFeatures[idx];
    st.patches = std::move(newPatches);
    st.freezeAddrs = std::move(newFreezeAddrs);

    if (applied > 0) {
        if (detail.empty()) detail = "ACTIVE";
        SetResultLocked(task.feature, true, true, false, detail);
    } else if (hasPythonFallback) {
        SetResultLocked(task.feature, true, true, false, "ACTIVE (BigWorld)");
    } else if (matched > 0) {
        SetResultLocked(task.feature, false, false, true, "Pattern matched; memory write failed");
    } else {
        SetResultLocked(task.feature, false, false, true, "Pattern not found (enter match)");
    }
}

void WorkerLoop() {
    while (true) {
        WorkerTask task{};
        {
            std::unique_lock<std::mutex> lock(gWorkerMutex);
            gWorkerCv.wait(lock, [] { return !gWorkerRunning || !gTaskQueue.empty(); });
            if (!gWorkerRunning && gTaskQueue.empty()) {
                return;
            }
            task = gTaskQueue.front();
            gTaskQueue.pop_front();
        }
        ExecuteTask(task);
    }
}

void ScanAndApplyFly(bool enable) {
    if (!enable) {
        std::lock_guard<std::mutex> lock(gFlyMutex);
        gFlyPatches.RestoreAll();
        return;
    }
    auto regions = QueryPreferredRegions(MachMemory::GetRegionMode());
    auto hits = MachMemory::GroupScan(
        regions,
        {MachMemory::SearchItem::Dword(0x686374U),
         MachMemory::SearchItem::Dword(0x74656b63U),
         MachMemory::SearchItem::Float(0.05f)},
        2, 512, 64, true);
    std::lock_guard<std::mutex> lock(gFlyMutex);
    ApplyFloatToTargets(gFlyPatches, hits, 20.5f);
}

void ScanAndApplyUnderground(bool enable) {
    if (!enable) {
        std::lock_guard<std::mutex> lock(gUndergroundMutex);
        gUndergroundPatches.RestoreAll();
        return;
    }
    auto regions = MachMemory::QueryRegions(MachMemory::RegionMode::Auto);
    auto qHits = MachMemory::ScanQword(regions, 0x656a624f00687072ULL, 512);
    std::vector<uintptr_t> animAddrs;
    for (uintptr_t addr : qHits) {
        uint64_t a = 0;
        uint64_t b = 0;
        if (addr >= 0x20 &&
            MachMemory::ReadValue(addr - 0x8, &a) && a == 0x6f4d6f54636e7953ULL &&
            MachMemory::ReadValue(addr - 0x20, &b) && b == 0x73754d00656e6f42ULL) {
            animAddrs.push_back(addr + 0x48);
        }
    }

    // Double scan (450.0 near 13.5 & 20.0 -> 135.0)
    auto wr = QueryPreferredRegions(MachMemory::GetRegionMode());
    std::vector<uint8_t> buf(65536 + 128);
    std::vector<uintptr_t> depthAddrs;
    for (const auto& reg : wr) {
        for (uintptr_t cur = reg.start; cur < reg.end; cur += 65536) {
            const size_t chunk = static_cast<size_t>(std::min<uintptr_t>(65536 + 112, reg.end - cur));
            const size_t limit = static_cast<size_t>(std::min<uintptr_t>(65536, reg.end - cur));
            if (chunk < 16 || !MachMemory::ReadMemory(cur, buf.data(), chunk)) continue;
            for (size_t off = 0; off < limit && off + 16 <= chunk; off += 4) {
                double d = 0.0;
                std::memcpy(&d, buf.data() + off, sizeof(d));
                if (std::fabs(d - 450.0) >= 0.1) continue;
                bool has135 = false;
                bool has20 = false;
                uintptr_t found135 = 0;
                for (size_t k = 0; k < 0x60 && off + 0x10 + k <= chunk; k += 8) {
                    double nd = 0.0;
                    std::memcpy(&nd, buf.data() + off + 8 + k, sizeof(nd));
                    if (std::fabs(nd - 13.5) < 0.01) {
                        has135 = true;
                        found135 = cur + off + 8 + k;
                    }
                    if (std::fabs(nd - 20.0) < 0.01) {
                        has20 = true;
                    }
                }
                if (has135 && has20 && found135 != 0) {
                    depthAddrs.push_back(found135);
                    if (depthAddrs.size() >= 16) break;
                }
            }
            if (depthAddrs.size() >= 16) break;
        }
        if (depthAddrs.size() >= 16) break;
    }

    std::lock_guard<std::mutex> lock(gUndergroundMutex);
    ApplyFloatToTargets(gUndergroundPatches, animAddrs, 4.0f);
    ApplyDoubleToTargets(gUndergroundPatches, depthAddrs, 135.0);
}

} // namespace

void Initialize() {
    std::lock_guard<std::mutex> lock(gWorkerMutex);
    if (gInitialized) return;
    gWorkerRunning = true;
    gWorkerThread = std::thread(WorkerLoop);
    gInitialized = true;
}

void Shutdown() {
    {
        std::lock_guard<std::mutex> lock(gWorkerMutex);
        if (!gInitialized) return;
        gWorkerRunning = false;
        gTaskQueue.clear();
    }
    gWorkerCv.notify_all();
    if (gWorkerThread.joinable()) {
        gWorkerThread.join();
    }
    gInitialized = false;
}

IosUIBridge::FeatureStatus GetStatus(IosUIBridge::MemoryFeature feature) {
    const size_t idx = static_cast<size_t>(feature);
    if (idx >= kFeatureCount) return {};
    std::lock_guard<std::mutex> lock(gStateMutex);
    const auto& st = gFeatures[idx];
    IosUIBridge::FeatureStatus out;
    out.enabled = st.enabled;
    out.pending = st.pending;
    out.error = st.error;
    out.active = st.active;
    out.detail = st.detail;
    return out;
}

bool RequestFeature(IosUIBridge::MemoryFeature feature, bool enable, float param) {
    const size_t idx = static_cast<size_t>(feature);
    if (idx >= kFeatureCount) return false;
    Initialize();

    {
        std::lock_guard<std::mutex> lock(gStateMutex);
        auto& st = gFeatures[idx];
        st.enabled = enable;
        st.pending = true;
        st.error = false;
        st.param = param;
        st.detail = enable ? "Applying..." : "Restoring...";
    }

    {
        std::lock_guard<std::mutex> lock(gWorkerMutex);
        gTaskQueue.push_back(WorkerTask{feature, enable, param});
    }
    gWorkerCv.notify_one();
    return true;
}

const char* GetFeatureName(IosUIBridge::MemoryFeature feature) {
    using MF = IosUIBridge::MemoryFeature;
    switch (feature) {
        case MF::AkmOneHit:       return "AKM One Hit";
        case MF::DesertEagleRpg:  return "Desert Eagle RPG";
        case MF::G18cRpg:         return "G18C RPG";
        case MF::M4a1OneHit:      return "M4A1 One Hit";
        case MF::OneHitAllGun:    return "One Hit All Guns";
        case MF::NoRecoil:        return "No Recoil";
        case MF::AutoScope:       return "Auto Scope";
        case MF::HighScope:       return "High Scope";
        case MF::FastShot:        return "Fast Shot";
        case MF::FastReload:      return "Fast Reload";
        case MF::FastHeal:        return "Fast Heal";
        case MF::SpeedHack:       return "Fast Move";
        case MF::WallV2:          return "Wall v2";
        case MF::NoFallDamage:    return "No Fall";
        case MF::NoGrass:         return "No Grass";
        case MF::FastParachute:   return "Fast Parachute";
        case MF::IpadView:        return "iPad View";
        case MF::ClearFog:        return "Clear Fog";
        case MF::P90OneHit:       return "P90 One Hit";
        case MF::QbzOneHit:       return "QBZ One Hit";
        case MF::Pp19OneHit:      return "PP19 One Hit";
        case MF::Mp5OneHit:       return "MP5 One Hit";
        case MF::VectorOneHit:    return "Vector One Hit";
        case MF::AkmRpg:          return "AKM RPG";
        case MF::FastParachuteV2: return "Fast Parachute v2";
        case MF::GhostDesync:     return "Ghost Desync";
        case MF::GhostVisual:     return "Ghost Visual";
        case MF::ClearWater:      return "Clear Water";
        case MF::WallV1:          return "Wall v1";
        case MF::SuperJump:       return "Super Jump";
        case MF::SpiderClimb:     return "Spider Climb";
        case MF::ZeroGravity:     return "Zero Gravity";
        case MF::MagicBullet:     return "Magic Bullet";
        case MF::WaterWalk:       return "Water Walk";
        case MF::InfiniteBreath:  return "Infinite Breath";
        case MF::AntiCheatShield: return "Anti-Cheat Shield";
        case MF::AutoReload:      return "Auto Reload";
        default:                  return "Feature";
    }
}

void SetSpeedMultiplier(float multiplier) {
    const float mult = std::clamp(multiplier, 1.1f, 50.0f);
    gSpeedMultiplier.store(mult, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(gStateMutex);
    auto& st = gFeatures[static_cast<size_t>(IosUIBridge::MemoryFeature::SpeedHack)];
    if (st.enabled && st.patches.Count() > 0) {
        const double dMult = static_cast<double>(mult);
        st.patches.UpdateAll(&dMult, sizeof(dMult));
        char buf[64];
        std::snprintf(buf, sizeof(buf), "ACTIVE (%.1fx)", mult);
        st.detail = buf;
    }
}

float GetSpeedMultiplier() {
    return gSpeedMultiplier.load(std::memory_order_relaxed);
}

bool GetFlyEnabled() {
    return gFlyEnabled.load(std::memory_order_relaxed);
}

void SetFlyEnabled(bool enabled) {
    gFlyEnabled.store(enabled, std::memory_order_relaxed);
    std::thread([enabled]() { ScanAndApplyFly(enabled); }).detach();
}

bool GetUndergroundEnabled() {
    return gUndergroundEnabled.load(std::memory_order_relaxed);
}

void SetUndergroundEnabled(bool enabled) {
    gUndergroundEnabled.store(enabled, std::memory_order_relaxed);
    std::thread([enabled]() { ScanAndApplyUnderground(enabled); }).detach();
}

void Tick() {
    std::lock_guard<std::mutex> lock(gStateMutex);

    // Re-freeze FastShot (100.0f)
    auto& fs = gFeatures[static_cast<size_t>(IosUIBridge::MemoryFeature::FastShot)];
    if (fs.enabled && !fs.freezeAddrs.empty()) {
        const float v = 100.0f;
        for (uintptr_t addr : fs.freezeAddrs) {
            MachMemory::WriteValue(addr, v);
        }
    }

    // Re-freeze NoFallDamage when game resets to -450.0f
    auto& nf = gFeatures[static_cast<size_t>(IosUIBridge::MemoryFeature::NoFallDamage)];
    if (nf.enabled && !nf.freezeAddrs.empty()) {
        for (uintptr_t addr : nf.freezeAddrs) {
            float cur = 0.0f;
            if (MachMemory::ReadValue(addr, &cur) && std::fabs(cur - (-450.0f)) < 1.0f) {
                const float safeVal = 180.0f;
                MachMemory::WriteValue(addr, safeVal);
            }
        }
    }

    // Auto-Reload: real-reload state machine
    // - IDLE     : mag > 0 → watch only
    // - EMPTY    : mag == 0 → do nothing, game animation runs naturally
    // - REFILLED : game wrote >0 after reload → override with maxMag, start cooldown
    if (gAutoReloadEnabled.load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lk(gAutoReloadMutex);
        for (auto& entry : gAutoReloadEntries) {
            uint32_t cur = 0;
            if (!MachMemory::ReadValue(entry.addr, &cur)) continue;

            switch (entry.state) {
                case AmmoState::Idle:
                    // Dynamically track the highest value seen as maxMag.
                    // This handles weapon swaps in the same slot: if the player
                    // picks up a UMP45 (45 rounds) where an AKM (30) was, the
                    // next IDLE ticks will raise maxMag to 45 before any reload.
                    if (cur > 0 && cur <= 200 && cur > entry.maxMag) {
                        entry.maxMag = cur;
                    }
                    if (cur == 0) {
                        entry.state = AmmoState::Empty;
                    }
                    break;

                case AmmoState::Empty:
                    // Waiting for reload — game animation is running.
                    // As soon as the game writes any >0 value back (reload done),
                    // we override it with the full maxMag.
                    if (cur > 0) {
                        MachMemory::WriteValue(entry.addr, entry.maxMag);
                        entry.state    = AmmoState::Refilled;
                        entry.cooldown = 12; // ~12 ticks before re-arming
                    }
                    break;

                case AmmoState::Refilled:
                    // Brief cooldown so we don't re-trigger on our own write
                    if (entry.cooldown > 0) {
                        --entry.cooldown;
                    } else {
                        entry.state = AmmoState::Idle;
                    }
                    break;
            }
        }
    }
}

std::string GetDiagnosticsSummary() {
    std::lock_guard<std::mutex> lock(gStateMutex);
    size_t activeCount = 0;
    for (size_t i = 0; i < kFeatureCount; ++i) {
        if (gFeatures[i].enabled && gFeatures[i].active) ++activeCount;
    }
    char buf[96];
    std::snprintf(buf, sizeof(buf), "mem active=%zu", activeCount);
    return buf;
}

} // namespace MemoryCheats
