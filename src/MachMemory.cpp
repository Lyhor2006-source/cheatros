#include "MachMemory.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>

#if defined(__APPLE__)
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_init.h>
#include <mach/vm_map.h>
#include <mach/vm_statistics.h>
#endif

namespace MachMemory {

namespace {

std::atomic<int> gRegionMode{static_cast<int>(RegionMode::Auto)};
constexpr size_t kReadChunkBytes = 65536;
constexpr size_t kStepBytes = 4;

#if defined(__APPLE__)
struct ImageSegmentRange {
    uintptr_t start = 0;
    uintptr_t end = 0;
    bool isOwnDylib = false;
    bool isAppBinary = false;
};

const void* GetOwnImageBase() {
    Dl_info info{};
    if (dladdr(reinterpret_cast<const void*>(&QueryRegions), &info) && info.dli_fbase) {
        return info.dli_fbase;
    }
    return nullptr;
}

std::vector<ImageSegmentRange> CollectLoadedSegments() {
    std::vector<ImageSegmentRange> segs;
    const void* ownBase = GetOwnImageBase();
    const uint32_t count = _dyld_image_count();

    for (uint32_t i = 0; i < count; ++i) {
        const auto* hdr = reinterpret_cast<const struct mach_header_64*>(_dyld_get_image_header(i));
        if (!hdr || hdr->magic != MH_MAGIC_64) continue;

        const uintptr_t slide = static_cast<uintptr_t>(_dyld_get_image_vmaddr_slide(i));
        const char* name = _dyld_get_image_name(i);
        const bool isOwn = (ownBase != nullptr && reinterpret_cast<const void*>(hdr) == ownBase);
        const bool isApp = (!isOwn && name != nullptr && std::strstr(name, ".app/") != nullptr);

        const uint8_t* ptr = reinterpret_cast<const uint8_t*>(hdr + 1);
        for (uint32_t c = 0; c < hdr->ncmds; ++c) {
            const auto* cmd = reinterpret_cast<const struct load_command*>(ptr);
            if (cmd->cmd == LC_SEGMENT_64 && cmd->cmdsize >= sizeof(struct segment_command_64)) {
                const auto* sc = reinterpret_cast<const struct segment_command_64*>(cmd);
                if (sc->vmsize > 0 && sc->vmaddr > 0) {
                    const uintptr_t sStart = static_cast<uintptr_t>(sc->vmaddr) + slide;
                    const uintptr_t sEnd = sStart + static_cast<uintptr_t>(sc->vmsize);
                    if (sEnd > sStart) {
                        segs.push_back(ImageSegmentRange{sStart, sEnd, isOwn, isApp});
                    }
                }
            }
            if (cmd->cmdsize == 0) break;
            ptr += cmd->cmdsize;
        }
    }
    return segs;
}

inline bool IsMallocUserTag(unsigned int tag) {
    // Malloc heap tags matching rosauthhook mask 0x3bde (1,2,3,4,6,7,8,9,11,12,13)
    return tag <= 13U && ((0x3bdeU >> tag) & 1U) != 0U;
}

bool IsAddressSafeToPatch(uintptr_t addr, size_t size) {
    if (!addr || size == 0 || addr < 0x100000000ULL || addr > 0x700000000000ULL) {
        return false;
    }

    // Never touch code/data inside own dylib or system frameworks
    Dl_info dlInfo{};
    if (dladdr(reinterpret_cast<const void*>(addr), &dlInfo) != 0) {
        if (dlInfo.dli_fbase == GetOwnImageBase()) {
            return false;
        }
        if (dlInfo.dli_fname && std::strstr(dlInfo.dli_fname, ".app/") == nullptr) {
            return false;
        }
    }

    vm_address_t qAddr = static_cast<vm_address_t>(addr);
    vm_size_t qSize = 0;
    natural_t depth = 0;
    vm_region_submap_info_data_64_t info{};
    while (true) {
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = vm_region_recurse_64(
            mach_task_self(),
            &qAddr,
            &qSize,
            &depth,
            reinterpret_cast<vm_region_info_t>(&info),
            &count);
        if (kr != KERN_SUCCESS || qSize == 0) return false;
        if (info.is_submap) {
            ++depth;
            continue;
        }
        break;
    }

    const uintptr_t rStart = static_cast<uintptr_t>(qAddr);
    const uintptr_t rEnd = rStart + static_cast<uintptr_t>(qSize);
    if (addr < rStart || addr + size > rEnd) {
        return false;
    }
    if ((info.protection & (VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE)) !=
        (VM_PROT_READ | VM_PROT_WRITE)) {
        return false;
    }
    if (info.user_tag == 30) {
        return false;
    }
    return true;
}
#endif

inline size_t ItemSize(const SearchItem& item) {
    return (item.type == SearchItem::Type::Qword || item.type == SearchItem::Type::Double) ? 8 : 4;
}

inline bool MatchSearchItem(const uint8_t* ptr, size_t availBytes, const SearchItem& item) {
    const size_t need = ItemSize(item);
    if (availBytes < need) return false;

    switch (item.type) {
        case SearchItem::Type::Dword: {
            uint32_t v = 0;
            std::memcpy(&v, ptr, sizeof(v));
            return v == static_cast<uint32_t>(item.val & 0xffffffffULL);
        }
        case SearchItem::Type::Float: {
            float v = 0.0f;
            float target = 0.0f;
            uint32_t targetBits = static_cast<uint32_t>(item.val & 0xffffffffULL);
            std::memcpy(&v, ptr, sizeof(v));
            std::memcpy(&target, &targetBits, sizeof(target));
            if (std::isnan(v) || std::isnan(target)) {
                uint32_t raw = 0;
                std::memcpy(&raw, ptr, sizeof(raw));
                return raw == targetBits;
            }
            if (targetBits != 0 && std::fabs(target) < 1e-6f) {
                uint32_t raw = 0;
                std::memcpy(&raw, ptr, sizeof(raw));
                return raw == targetBits;
            }
            return std::fabs(v - target) <= 0.01f;
        }
        case SearchItem::Type::Qword: {
            uint64_t v = 0;
            std::memcpy(&v, ptr, sizeof(v));
            return v == item.val;
        }
        case SearchItem::Type::Double: {
            double v = 0.0;
            double target = 0.0;
            std::memcpy(&v, ptr, sizeof(v));
            std::memcpy(&target, &item.val, sizeof(target));
            if (std::isnan(v) || std::isnan(target)) {
                uint64_t raw = 0;
                std::memcpy(&raw, ptr, sizeof(raw));
                return raw == item.val;
            }
            return std::fabs(v - target) <= 0.01;
        }
    }
    return false;
}

} // namespace

RegionMode GetRegionMode() {
    return static_cast<RegionMode>(gRegionMode.load(std::memory_order_relaxed));
}

void SetRegionMode(RegionMode mode) {
    gRegionMode.store(static_cast<int>(mode), std::memory_order_relaxed);
}

std::vector<MemoryRegion> QueryRegions(RegionMode mode) {
    std::vector<MemoryRegion> out;
#if defined(__APPLE__)
    const auto segments = CollectLoadedSegments();
    vm_address_t addr = 0;
    natural_t depth = 0;

    while (true) {
        vm_size_t size = 0;
        vm_region_submap_info_data_64_t info{};
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;

        kern_return_t kr = vm_region_recurse_64(
            mach_task_self(),
            &addr,
            &size,
            &depth,
            reinterpret_cast<vm_region_info_t>(&info),
            &count);
        if (kr != KERN_SUCCESS || size == 0) {
            break;
        }
        if (info.is_submap) {
            ++depth;
            continue;
        }

        const uintptr_t start = static_cast<uintptr_t>(addr);
        const uintptr_t end = start + static_cast<uintptr_t>(size);
        const bool rwOnly =
            (info.protection & (VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE)) ==
            (VM_PROT_READ | VM_PROT_WRITE);
        const bool sensibleRange =
            (start >= 0x100000000ULL &&
             end > start &&
             end <= 0x700000000000ULL &&
             size >= 4096 &&
             size <= (256u * 1024u * 1024u));

        bool inOwn = false;
        bool inSys = false;
        bool inApp = false;
        for (const auto& seg : segments) {
            if (start < seg.end && end > seg.start) {
                if (seg.isOwnDylib) inOwn = true;
                else if (seg.isAppBinary) inApp = true;
                else inSys = true;
            }
        }

        bool include = false;
        if (rwOnly && sensibleRange && !inOwn && !inSys && info.user_tag != 30) {
            switch (mode) {
                case RegionMode::WritableOnly:
                    // Writable heap regions outside Mach-O binaries (no user_tag >= 60 cap)
                    include = (!inApp);
                    break;
                case RegionMode::Standard:
                    // SM_PRIVATE / SM_COW regions matching rosauthhook RegionMode::Standard
                    include = (info.share_mode == SM_PRIVATE || info.share_mode == SM_COW);
                    break;
                case RegionMode::Auto:
                    include = inApp || IsMallocUserTag(info.user_tag) || info.user_tag == 0;
                    break;
                case RegionMode::All:
                    include = true;
                    break;
            }
        }

        if (include) {
            if (!out.empty() && out.back().end == start && out.back().protection == info.protection) {
                out.back().end = end;
            } else {
                out.push_back(MemoryRegion{start, end, info.protection});
            }
        }

        if (end <= addr) break;
        addr = static_cast<vm_address_t>(end);
    }
#else
    (void)mode;
#endif
    return out;
}

std::vector<MemoryRegion> QueryAllWritableRegions() {
    return QueryRegions(RegionMode::Auto);
}

bool ReadMemory(uintptr_t addr, void* out, size_t size) {
    if (!addr || !out || size == 0) return false;
#if defined(__APPLE__)
    vm_size_t outSize = 0;
    const kern_return_t kr = vm_read_overwrite(
        mach_task_self(),
        static_cast<vm_address_t>(addr),
        static_cast<vm_size_t>(size),
        reinterpret_cast<vm_address_t>(out),
        &outSize);
    return kr == KERN_SUCCESS && static_cast<size_t>(outSize) == size;
#else
    (void)addr;
    (void)out;
    (void)size;
    return false;
#endif
}

bool WriteMemory(uintptr_t addr, const void* data, size_t size) {
    if (!addr || !data || size == 0) return false;
#if defined(__APPLE__)
    const kern_return_t kr = vm_write(
        mach_task_self(),
        static_cast<vm_address_t>(addr),
        reinterpret_cast<vm_offset_t>(const_cast<void*>(data)),
        static_cast<mach_msg_type_number_t>(size));
    return kr == KERN_SUCCESS;
#else
    (void)addr;
    (void)data;
    (void)size;
    return false;
#endif
}

void PatchState::Clear() {
    entries_.clear();
}

bool PatchState::AddAndApply(uintptr_t addr, const void* newData, size_t size) {
    if (!addr || !newData || size == 0) return false;
#if defined(__APPLE__)
    if (!IsAddressSafeToPatch(addr, size)) {
        return false;
    }
#endif

    std::vector<uint8_t> orig(size);
    if (!ReadMemory(addr, orig.data(), size)) {
        return false;
    }
    if (!WriteMemory(addr, newData, size)) {
        return false;
    }

    std::vector<uint8_t> verify(size);
    if (!ReadMemory(addr, verify.data(), size) || std::memcmp(verify.data(), newData, size) != 0) {
        return false;
    }

    for (auto& existing : entries_) {
        if (existing.addr == addr) {
            existing.patched.assign(static_cast<const uint8_t*>(newData), static_cast<const uint8_t*>(newData) + size);
            return true;
        }
    }

    PatchEntry entry;
    entry.addr = addr;
    entry.original = std::move(orig);
    entry.patched.assign(static_cast<const uint8_t*>(newData), static_cast<const uint8_t*>(newData) + size);
    entries_.push_back(std::move(entry));
    return true;
}

size_t PatchState::UpdateAll(const void* newData, size_t size) {
    if (!newData || size == 0) return 0;
    size_t updated = 0;
    for (auto& entry : entries_) {
        if (entry.patched.size() != size) continue;
#if defined(__APPLE__)
        if (!IsAddressSafeToPatch(entry.addr, size)) continue;
#endif
        if (WriteMemory(entry.addr, newData, size)) {
            entry.patched.assign(static_cast<const uint8_t*>(newData), static_cast<const uint8_t*>(newData) + size);
            ++updated;
        }
    }
    return updated;
}

size_t PatchState::RestoreAll(size_t* outRemaining) {
    size_t restored = 0;
    std::vector<PatchEntry> remaining;
    remaining.reserve(entries_.size());

    for (auto& entry : entries_) {
        std::vector<uint8_t> cur(entry.original.size());
        if (ReadMemory(entry.addr, cur.data(), cur.size()) &&
            WriteMemory(entry.addr, entry.original.data(), entry.original.size())) {
            ++restored;
        } else {
            remaining.push_back(std::move(entry));
        }
    }
    entries_.swap(remaining);
    if (outRemaining) {
        *outRemaining = entries_.size();
    }
    return restored;
}

std::vector<uintptr_t> ScanDword(
    const std::vector<MemoryRegion>& regions,
    uint32_t value,
    size_t maxResults) {
    std::vector<uintptr_t> results;
    std::vector<uint8_t> buf(kReadChunkBytes);

    for (const auto& reg : regions) {
        for (uintptr_t cur = reg.start; cur < reg.end; cur += kReadChunkBytes) {
            const size_t chunk = static_cast<size_t>(std::min<uintptr_t>(kReadChunkBytes, reg.end - cur));
            if (chunk < sizeof(uint32_t)) break;
            if (!ReadMemory(cur, buf.data(), chunk)) continue;

            for (size_t off = 0; off + sizeof(uint32_t) <= chunk; off += kStepBytes) {
                uint32_t v = 0;
                std::memcpy(&v, buf.data() + off, sizeof(v));
                if (v == value) {
                    results.push_back(cur + off);
                    if (results.size() >= maxResults) return results;
                }
            }
        }
    }
    return results;
}

std::vector<uintptr_t> ScanQword(
    const std::vector<MemoryRegion>& regions,
    uint64_t value,
    size_t maxResults) {
    std::vector<uintptr_t> results;
    std::vector<uint8_t> buf(kReadChunkBytes);

    for (const auto& reg : regions) {
        for (uintptr_t cur = reg.start; cur < reg.end; cur += kReadChunkBytes) {
            const size_t chunk = static_cast<size_t>(std::min<uintptr_t>(kReadChunkBytes, reg.end - cur));
            if (chunk < sizeof(uint64_t)) break;
            if (!ReadMemory(cur, buf.data(), chunk)) continue;

            for (size_t off = 0; off + sizeof(uint64_t) <= chunk; off += kStepBytes) {
                uint64_t v = 0;
                std::memcpy(&v, buf.data() + off, sizeof(v));
                if (v == value) {
                    results.push_back(cur + off);
                    if (results.size() >= maxResults) return results;
                }
            }
        }
    }
    return results;
}

std::vector<uintptr_t> ScanFloat(
    const std::vector<MemoryRegion>& regions,
    float value,
    float tolerance,
    size_t maxResults) {
    std::vector<uintptr_t> results;
    std::vector<uint8_t> buf(kReadChunkBytes);

    for (const auto& reg : regions) {
        for (uintptr_t cur = reg.start; cur < reg.end; cur += kReadChunkBytes) {
            const size_t chunk = static_cast<size_t>(std::min<uintptr_t>(kReadChunkBytes, reg.end - cur));
            if (chunk < sizeof(float)) break;
            if (!ReadMemory(cur, buf.data(), chunk)) continue;

            for (size_t off = 0; off + sizeof(float) <= chunk; off += kStepBytes) {
                float v = 0.0f;
                std::memcpy(&v, buf.data() + off, sizeof(v));
                if (!std::isnan(v) && std::fabs(v - value) <= tolerance) {
                    results.push_back(cur + off);
                    if (results.size() >= maxResults) return results;
                }
            }
        }
    }
    return results;
}

std::vector<uintptr_t> ScanDouble(
    const std::vector<MemoryRegion>& regions,
    double value,
    double tolerance,
    size_t maxResults) {
    std::vector<uintptr_t> results;
    std::vector<uint8_t> buf(kReadChunkBytes);

    for (const auto& reg : regions) {
        for (uintptr_t cur = reg.start; cur < reg.end; cur += kReadChunkBytes) {
            const size_t chunk = static_cast<size_t>(std::min<uintptr_t>(kReadChunkBytes, reg.end - cur));
            if (chunk < sizeof(double)) break;
            if (!ReadMemory(cur, buf.data(), chunk)) continue;

            for (size_t off = 0; off + sizeof(double) <= chunk; off += kStepBytes) {
                double v = 0.0;
                std::memcpy(&v, buf.data() + off, sizeof(v));
                if (!std::isnan(v) && std::fabs(v - value) <= tolerance) {
                    results.push_back(cur + off);
                    if (results.size() >= maxResults) return results;
                }
            }
        }
    }
    return results;
}

std::vector<uintptr_t> ProximityScan(
    const std::vector<MemoryRegion>& regions,
    const SearchItem& anchor,
    const SearchItem& target,
    size_t maxRangeBytes,
    size_t maxResults) {
    std::vector<SearchItem> items = {anchor, target};
    return GroupScan(regions, items, 1, maxRangeBytes, maxResults, false);
}

std::vector<uintptr_t> GroupScan(
    const std::vector<MemoryRegion>& regions,
    const std::vector<SearchItem>& items,
    size_t targetIndex,
    size_t maxSpanBytes,
    size_t maxResults,
    bool ordered) {
    if (items.empty() || targetIndex >= items.size()) return {};
    return GroupScanMany(regions, items, {targetIndex}, maxSpanBytes, maxResults, ordered, nullptr);
}

std::vector<uintptr_t> GroupScanMany(
    const std::vector<MemoryRegion>& regions,
    const std::vector<SearchItem>& items,
    const std::vector<size_t>& targetIndices,
    size_t maxSpanBytes,
    size_t maxResults,
    bool ordered,
    std::vector<uintptr_t>* outAnchorAddrs) {
    std::vector<uintptr_t> results;
    if (outAnchorAddrs) outAnchorAddrs->clear();
    if (items.empty() || targetIndices.empty()) return results;
    for (size_t ti : targetIndices) {
        if (ti >= items.size()) return results;
    }

    const size_t overlap = std::min<size_t>(std::max<size_t>(maxSpanBytes + 16, 64), 4096);
    std::vector<uint8_t> buf(kReadChunkBytes + overlap);
    size_t groupsMatched = 0;

    for (const auto& reg : regions) {
        for (uintptr_t cur = reg.start; cur < reg.end; cur += kReadChunkBytes) {
            const size_t chunk = static_cast<size_t>(std::min<uintptr_t>(kReadChunkBytes + overlap, reg.end - cur));
            const size_t baseLimit = static_cast<size_t>(std::min<uintptr_t>(kReadChunkBytes, reg.end - cur));
            if (chunk < ItemSize(items[0])) break;
            if (!ReadMemory(cur, buf.data(), chunk)) continue;

            for (size_t off = 0; off < baseLimit; off += kStepBytes) {
                if (!MatchSearchItem(buf.data() + off, chunk - off, items[0])) {
                    continue;
                }

                std::vector<size_t> matchedOffsets(items.size(), 0);
                matchedOffsets[0] = off;
                bool allOk = true;
                size_t searchStart = off + ItemSize(items[0]);
                const size_t winStart = ordered ? searchStart : (off > maxSpanBytes ? off - maxSpanBytes : 0);
                const size_t winEnd = std::min<size_t>(chunk, off + maxSpanBytes);

                for (size_t idx = 1; idx < items.size(); ++idx) {
                    const size_t need = ItemSize(items[idx]);
                    const size_t begin = ordered ? searchStart : winStart;
                    bool foundItem = false;
                    for (size_t scan = begin; scan + need <= winEnd; scan += kStepBytes) {
                        bool alreadyUsed = false;
                        for (size_t prev = 0; prev < idx; ++prev) {
                            if (matchedOffsets[prev] == scan) {
                                alreadyUsed = true;
                                break;
                            }
                        }
                        if (alreadyUsed) continue;
                        if (MatchSearchItem(buf.data() + scan, chunk - scan, items[idx])) {
                            matchedOffsets[idx] = scan;
                            if (ordered) {
                                searchStart = scan + need;
                            }
                            foundItem = true;
                            break;
                        }
                    }
                    if (!foundItem) {
                        allOk = false;
                        break;
                    }
                }

                if (!allOk) continue;

                if (outAnchorAddrs) {
                    outAnchorAddrs->push_back(cur + off);
                }
                for (size_t ti : targetIndices) {
                    results.push_back(cur + matchedOffsets[ti]);
                }
                ++groupsMatched;
                if (groupsMatched >= maxResults) {
                    return results;
                }
            }
        }
    }

    return results;
}

} // namespace MachMemory
