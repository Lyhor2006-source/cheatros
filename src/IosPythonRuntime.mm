#import "IosPythonRuntime.h"
#include "MachMemory.h"

#include <atomic>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mutex>

namespace IosPythonRuntime {

namespace {

using FnPyIsInitialized = int (*)(void);
using FnPyGILStateEnsure = int (*)(void);
using FnPyGILStateRelease = void (*)(int);
using FnPyImportAddModule = void* (*)(const char*);
using FnPyModuleGetDict = void* (*)(void*);
using FnPyRunStringFlags = void* (*)(const char*, int, void*, void*, void*);
using FnPyErrClear = void (*)(void);
using FnPyDecRef = void (*)(void*);

struct SymbolTable {
    FnPyIsInitialized Py_IsInitialized = nullptr;
    FnPyGILStateEnsure PyGILState_Ensure = nullptr;
    FnPyGILStateRelease PyGILState_Release = nullptr;
    FnPyImportAddModule PyImport_AddModule = nullptr;
    FnPyModuleGetDict PyModule_GetDict = nullptr;
    FnPyRunStringFlags PyRun_StringFlags = nullptr;
    FnPyErrClear PyErr_Clear = nullptr;
    FnPyDecRef Py_DecRef = nullptr;
    bool resolvedByDlsym = false;
    bool resolvedBySlide = false;
    std::string status = "uninitialized";
};

std::mutex gPyMutex;
SymbolTable gSyms;

bool AllCoreSymbolsPresent(const SymbolTable& s) {
    return s.Py_IsInitialized &&
           s.PyGILState_Ensure &&
           s.PyGILState_Release &&
           s.PyImport_AddModule &&
           s.PyModule_GetDict &&
           s.PyRun_StringFlags &&
           s.PyErr_Clear;
}

bool CheckUuidMatchesRos(const struct mach_header_64* hdr) {
    if (!hdr || hdr->magic != MH_MAGIC_64) return false;
    const uint8_t* ptr = reinterpret_cast<const uint8_t*>(hdr + 1);
    for (uint32_t i = 0; i < hdr->ncmds; ++i) {
        const auto* cmd = reinterpret_cast<const struct load_command*>(ptr);
        if (cmd->cmd == LC_UUID && cmd->cmdsize >= sizeof(struct uuid_command)) {
            const auto* ucmd = reinterpret_cast<const struct uuid_command*>(cmd);
            uint64_t lo = 0;
            uint64_t hi = 0;
            std::memcpy(&lo, ucmd->uuid, sizeof(lo));
            std::memcpy(&hi, ucmd->uuid + 8, sizeof(hi));
            // Verified UUID of Rules of Survival iOS 1.610637.617289 binary
            return lo == 0x59317c7611781743ULL && hi == 0x9813a113c0ee0082ULL;
        }
        if (cmd->cmdsize == 0) break;
        ptr += cmd->cmdsize;
    }
    return false;
}

template <typename Fn>
Fn ResolveSlideChecked(uintptr_t slide, uintptr_t vmAddr, uint64_t expectedQ0, uint64_t expectedQ1) {
    const uintptr_t addr = slide + vmAddr;
    uint64_t q[2] = {};
    if (!MachMemory::ReadMemory(addr, q, sizeof(q))) {
        return nullptr;
    }
    if (q[0] != expectedQ0 || q[1] != expectedQ1) {
        return nullptr;
    }
    return reinterpret_cast<Fn>(addr);
}

bool ResolveLocked() {
    if (AllCoreSymbolsPresent(gSyms)) return true;

    gSyms.Py_IsInitialized = reinterpret_cast<FnPyIsInitialized>(dlsym(RTLD_DEFAULT, "Py_IsInitialized"));
    gSyms.PyGILState_Ensure = reinterpret_cast<FnPyGILStateEnsure>(dlsym(RTLD_DEFAULT, "PyGILState_Ensure"));
    gSyms.PyGILState_Release = reinterpret_cast<FnPyGILStateRelease>(dlsym(RTLD_DEFAULT, "PyGILState_Release"));
    gSyms.PyImport_AddModule = reinterpret_cast<FnPyImportAddModule>(dlsym(RTLD_DEFAULT, "PyImport_AddModule"));
    gSyms.PyModule_GetDict = reinterpret_cast<FnPyModuleGetDict>(dlsym(RTLD_DEFAULT, "PyModule_GetDict"));
    gSyms.PyRun_StringFlags = reinterpret_cast<FnPyRunStringFlags>(dlsym(RTLD_DEFAULT, "PyRun_StringFlags"));
    gSyms.PyErr_Clear = reinterpret_cast<FnPyErrClear>(dlsym(RTLD_DEFAULT, "PyErr_Clear"));
    gSyms.Py_DecRef = reinterpret_cast<FnPyDecRef>(dlsym(RTLD_DEFAULT, "Py_DecRef"));

    if (AllCoreSymbolsPresent(gSyms)) {
        gSyms.resolvedByDlsym = true;
        gSyms.status = "resolved via dlsym";
        return true;
    }

    const auto* hdr = reinterpret_cast<const struct mach_header_64*>(_dyld_get_image_header(0));
    if (!CheckUuidMatchesRos(hdr)) {
        gSyms.status = "dlsym incomplete & binary UUID mismatch";
        return false;
    }

    const uintptr_t slide = static_cast<uintptr_t>(_dyld_get_image_vmaddr_slide(0));
    if (!gSyms.Py_IsInitialized) {
        gSyms.Py_IsInitialized = ResolveSlideChecked<FnPyIsInitialized>(
            slide, 0x101d05a24ULL, 0x39674100900133e8ULL, 0xd10203ffd65f03c0ULL);
    }
    if (!gSyms.PyGILState_Ensure) {
        gSyms.PyGILState_Ensure = ResolveSlideChecked<FnPyGILStateEnsure>(
            slide, 0x101d05158ULL, 0xa9017bfda9be4ff4ULL, 0x900133e8910043fdULL);
    }
    if (!gSyms.PyGILState_Release) {
        gSyms.PyGILState_Release = ResolveSlideChecked<FnPyGILStateRelease>(
            slide, 0x101d051dcULL, 0xa9014ff4a9bd57f6ULL, 0x910083fda9027bfdULL);
    }
    if (!gSyms.PyImport_AddModule) {
        gSyms.PyImport_AddModule = ResolveSlideChecked<FnPyImportAddModule>(
            slide, 0x101cf8fd4ULL, 0xa9014ff4a9bd57f6ULL, 0x910083fda9027bfdULL);
    }
    if (!gSyms.PyModule_GetDict) {
        gSyms.PyModule_GetDict = ResolveSlideChecked<FnPyModuleGetDict>(
            slide, 0x101c79884ULL, 0xa9017bfda9be4ff4ULL, 0xaa0003f3910043fdULL);
    }
    if (!gSyms.PyRun_StringFlags) {
        gSyms.PyRun_StringFlags = ResolveSlideChecked<FnPyRunStringFlags>(
            slide, 0x101d0689cULL, 0xa90157f6a9bc5ff8ULL, 0xa9037bfda9024ff4ULL);
    }
    if (!gSyms.PyErr_Clear) {
        gSyms.PyErr_Clear = ResolveSlideChecked<FnPyErrClear>(
            slide, 0x101cf17f0ULL, 0xa9017bfda9be4ff4ULL, 0xd0013f08910043fdULL);
    }

    if (AllCoreSymbolsPresent(gSyms)) {
        gSyms.resolvedBySlide = true;
        gSyms.status = "resolved via UUID/slide fallback";
        return true;
    }

    gSyms.status = "UUID matched but prologue verification failed";
    return false;
}

} // namespace

bool Resolve() {
    std::lock_guard<std::mutex> lock(gPyMutex);
    return ResolveLocked();
}

bool IsResolved() {
    std::lock_guard<std::mutex> lock(gPyMutex);
    return AllCoreSymbolsPresent(gSyms);
}

bool IsPythonInitialized() {
    std::lock_guard<std::mutex> lock(gPyMutex);
    if (!ResolveLocked()) return false;
    return gSyms.Py_IsInitialized() != 0;
}

bool Execute(const std::string& code, std::string* outError) {
    if (code.empty()) return false;
    std::lock_guard<std::mutex> lock(gPyMutex);
    if (!ResolveLocked()) {
        if (outError) *outError = gSyms.status;
        return false;
    }
    if (gSyms.Py_IsInitialized() == 0) {
        if (outError) *outError = "Python runtime not initialized yet";
        return false;
    }

    constexpr int kPyFileInput = 257;
    const int gstate = gSyms.PyGILState_Ensure();
    bool ok = false;

    void* mainMod = gSyms.PyImport_AddModule("__main__");
    void* globalsDict = mainMod ? gSyms.PyModule_GetDict(mainMod) : nullptr;
    if (globalsDict) {
        void* res = gSyms.PyRun_StringFlags(code.c_str(), kPyFileInput, globalsDict, globalsDict, nullptr);
        if (res) {
            if (gSyms.Py_DecRef) {
                gSyms.Py_DecRef(res);
            }
            ok = true;
        } else {
            gSyms.PyErr_Clear();
            if (outError) *outError = "Python execution raised an exception";
        }
    } else {
        gSyms.PyErr_Clear();
        if (outError) *outError = "Failed to acquire __main__ dict";
    }

    gSyms.PyGILState_Release(gstate);
    return ok;
}

std::string GetDiagnostics() {
    std::lock_guard<std::mutex> lock(gPyMutex);
    return gSyms.status;
}

} // namespace IosPythonRuntime
