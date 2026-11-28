#import "AntiCheatBypass.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <atomic>
#include <cstdint>
#include <cstring>

#if defined(__APPLE__)
#include <libkern/OSCacheControl.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_init.h>
#include <mach/vm_map.h>
#endif

namespace AntiCheatBypass {

namespace {

std::atomic<bool> gPatchesApplied{false};

#if defined(__APPLE__)

bool SafePatchCode(uintptr_t addr, const void* data, size_t size) {
    if (!addr || !data || size == 0) return false;

    vm_size_t pageSize = vm_page_size ? vm_page_size : 4096;
    vm_address_t pageStart = addr & ~(pageSize - 1);
    vm_address_t pageEnd = (addr + size + pageSize - 1) & ~(pageSize - 1);
    vm_size_t protectSize = pageEnd - pageStart;

    kern_return_t kr = vm_protect(
        mach_task_self(),
        pageStart,
        protectSize,
        FALSE,
        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        return false;
    }

    std::memcpy(reinterpret_cast<void*>(addr), data, size);

    vm_protect(
        mach_task_self(),
        pageStart,
        protectSize,
        FALSE,
        VM_PROT_READ | VM_PROT_EXECUTE);

    sys_icache_invalidate(reinterpret_cast<void*>(addr), size);

    return true;
}

void PatchClientBinary(uintptr_t slide) {
    // 1. is_outlaw_device: force Py_False
    const uint32_t patchOutlaw = 0xe00308aa; // mov x0, x8
    SafePatchCode(slide + 0x10104af90ULL, &patchOutlaw, sizeof(patchOutlaw));

    // 2. inspect_loaded_modules: nop blr x8
    const uint32_t patchNop = 0x1f2003d5; // nop
    SafePatchCode(slide + 0x10104d664ULL, &patchNop, sizeof(patchNop));

    // 3. mobile_acsdk_check: zero stack SSO buffer, skip blr x9
    const uint32_t patchAcsdk[2] = {0xff0700f9, 0xff7f0039}; // str xzr, [sp, #8]; strb wzr, [sp, #0x1f]
    SafePatchCode(slide + 0x10104d4e0ULL, patchAcsdk, sizeof(patchAcsdk));

    // 4. anti_cheat_check: zero 8-byte output buffer, skip blr x8
    const uint32_t patchAcCheck = 0xbf031ff8; // stur xzr, [x29, #-0x10]
    SafePatchCode(slide + 0x10104cddcULL, &patchAcCheck, sizeof(patchAcCheck));

    // 5. check_graphic_states: force Py_False (hide overlay)
    const uint32_t patchGraphic = 0xe00308aa; // mov x0, x8
    SafePatchCode(slide + 0x10104d710ULL, &patchGraphic, sizeof(patchGraphic));

    // 6. inspect_system_processes: nop blr x8
    SafePatchCode(slide + 0x10104d740ULL, &patchNop, sizeof(patchNop));

    // 7. inspect_system_windows: nop blr x8
    SafePatchCode(slide + 0x10104d778ULL, &patchNop, sizeof(patchNop));
}

void PatchHkFramework(uintptr_t slide) {
    const uint32_t patchNop = 0x1f2003d5; // nop
    const uint32_t patchRet = 0xc0035fd6; // ret

    // HK dyld callback registration
    SafePatchCode(slide + 0x4014ULL, &patchNop, sizeof(patchNop));

    // HK auto-ban / report sender
    SafePatchCode(slide + 0x537cULL, &patchRet, sizeof(patchRet));
}

void OnImageAdded(const struct mach_header* header, intptr_t slide) {
    if (!header || header->magic != MH_MAGIC_64) return;
    Dl_info info{};
    if (dladdr(header, &info) && info.dli_fname) {
        if (std::strstr(info.dli_fname, "HK.framework/HK") || std::strstr(info.dli_fname, "/HK")) {
            PatchHkFramework(static_cast<uintptr_t>(slide));
        }
    }
}

// Swizzle UIDevice identifierForVendor to provide a clean non-banned UUID
static NSUUID* (*sOrigIdentifierForVendor)(id, SEL) = nullptr;

static NSUUID* HookedIdentifierForVendor(id self, SEL _cmd) {
    static NSUUID* sSpoofedUuid = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"_ryomenx_spoofed_idfv"];
        if (saved && saved.length > 0) {
            sSpoofedUuid = [[NSUUID alloc] initWithUUIDString:saved];
        }
        if (!sSpoofedUuid) {
            sSpoofedUuid = [[NSUUID alloc] init];
            [[NSUserDefaults standardUserDefaults] setObject:[sSpoofedUuid UUIDString]
                                                      forKey:@"_ryomenx_spoofed_idfv"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
    });
    return sSpoofedUuid ?: (sOrigIdentifierForVendor ? sOrigIdentifierForVendor(self, _cmd) : [[NSUUID alloc] init]);
}

void InstallDeviceSpoofing() {
    Method m = class_getInstanceMethod([UIDevice class], @selector(identifierForVendor));
    if (m) {
        sOrigIdentifierForVendor = reinterpret_cast<NSUUID* (*)(id, SEL)>(method_getImplementation(m));
        method_setImplementation(m, reinterpret_cast<IMP>(HookedIdentifierForVendor));
    }
}

#endif

} // namespace

void InstallRuntimeHooks() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#if defined(__APPLE__)
        // 1. Patch main executable client binary
        const uintptr_t clientSlide = static_cast<uintptr_t>(_dyld_get_image_vmaddr_slide(0));
        PatchClientBinary(clientSlide);

        // 2. Scan currently loaded images for HK.framework
        const uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; ++i) {
            const char* name = _dyld_get_image_name(i);
            if (name && (std::strstr(name, "HK.framework/HK") || std::strstr(name, "/HK"))) {
                const uintptr_t hkSlide = static_cast<uintptr_t>(_dyld_get_image_vmaddr_slide(i));
                PatchHkFramework(hkSlide);
                break;
            }
        }

        // 3. Register callback for late HK loading
        _dyld_register_func_for_add_image(OnImageAdded);

        // 4. Install device IDFV spoofer to defeat device bans
        InstallDeviceSpoofing();

        gPatchesApplied = true;
#endif
    });
}

bool IsActive() {
    return gPatchesApplied.load();
}

} // namespace AntiCheatBypass
