#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace MachMemory {

enum class RegionMode : int {
    Auto = 0,
    WritableOnly = 1,
    Standard = 2,
    All = 3,
};

struct MemoryRegion {
    uintptr_t start = 0;
    uintptr_t end = 0;
    int protection = 0;
};

struct SearchItem {
    enum class Type : uint32_t {
        Dword = 0,
        Float = 1,
        Qword = 2,
        Double = 3,
    };

    Type type = Type::Dword;
    uint32_t pad = 0;
    uint64_t val = 0;

    static SearchItem Dword(uint32_t v) {
        SearchItem item;
        item.type = Type::Dword;
        item.val = static_cast<uint64_t>(v);
        return item;
    }

    static SearchItem FloatBits(uint32_t bits) {
        SearchItem item;
        item.type = Type::Float;
        item.val = static_cast<uint64_t>(bits);
        return item;
    }

    static SearchItem Float(float v) {
        uint32_t bits = 0;
        std::memcpy(&bits, &v, sizeof(bits));
        return FloatBits(bits);
    }

    static SearchItem Qword(uint64_t v) {
        SearchItem item;
        item.type = Type::Qword;
        item.val = v;
        return item;
    }

    static SearchItem Double(double v) {
        uint64_t bits = 0;
        std::memcpy(&bits, &v, sizeof(bits));
        SearchItem item;
        item.type = Type::Double;
        item.val = bits;
        return item;
    }
};

struct PatchEntry {
    uintptr_t addr = 0;
    std::vector<uint8_t> original;
    std::vector<uint8_t> patched;
};

class PatchState {
public:
    void Clear();
    bool AddAndApply(uintptr_t addr, const void* newData, size_t size);
    size_t UpdateAll(const void* newData, size_t size);
    size_t RestoreAll(size_t* outRemaining = nullptr);
    size_t Count() const { return entries_.size(); }
    const std::vector<PatchEntry>& Entries() const { return entries_; }

private:
    std::vector<PatchEntry> entries_;
};

RegionMode GetRegionMode();
void SetRegionMode(RegionMode mode);

std::vector<MemoryRegion> QueryRegions(RegionMode mode);
std::vector<MemoryRegion> QueryAllWritableRegions();

bool ReadMemory(uintptr_t addr, void* out, size_t size);
bool WriteMemory(uintptr_t addr, const void* data, size_t size);

template <typename T>
inline bool ReadValue(uintptr_t addr, T* out) {
    return out != nullptr && ReadMemory(addr, out, sizeof(T));
}

template <typename T>
inline bool WriteValue(uintptr_t addr, const T& value) {
    return WriteMemory(addr, &value, sizeof(T));
}

std::vector<uintptr_t> ScanDword(
    const std::vector<MemoryRegion>& regions,
    uint32_t value,
    size_t maxResults = 256);

std::vector<uintptr_t> ScanQword(
    const std::vector<MemoryRegion>& regions,
    uint64_t value,
    size_t maxResults = 256);

std::vector<uintptr_t> ScanFloat(
    const std::vector<MemoryRegion>& regions,
    float value,
    float tolerance = 0.01f,
    size_t maxResults = 256);

std::vector<uintptr_t> ScanDouble(
    const std::vector<MemoryRegion>& regions,
    double value,
    double tolerance = 0.01,
    size_t maxResults = 256);

std::vector<uintptr_t> ProximityScan(
    const std::vector<MemoryRegion>& regions,
    const SearchItem& anchor,
    const SearchItem& target,
    size_t maxRangeBytes,
    size_t maxResults = 64);

std::vector<uintptr_t> GroupScan(
    const std::vector<MemoryRegion>& regions,
    const std::vector<SearchItem>& items,
    size_t targetIndex,
    size_t maxSpanBytes,
    size_t maxResults = 64,
    bool ordered = true);

std::vector<uintptr_t> GroupScanMany(
    const std::vector<MemoryRegion>& regions,
    const std::vector<SearchItem>& items,
    const std::vector<size_t>& targetIndices,
    size_t maxSpanBytes,
    size_t maxResults = 64,
    bool ordered = true,
    std::vector<uintptr_t>* outAnchorAddrs = nullptr);

} // namespace MachMemory
