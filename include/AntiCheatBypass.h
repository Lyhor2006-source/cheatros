#pragma once

#include <cstdint>

namespace AntiCheatBypass {

// Applies all runtime in-memory anti-cheat patches to client and HK.framework.
// Also installs device identifier spoofing to bypass device bans.
void InstallRuntimeHooks();

// Returns true if all runtime patches have been verified in memory.
bool IsActive();

} // namespace AntiCheatBypass
