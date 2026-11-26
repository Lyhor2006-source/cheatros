#pragma once

#include "IosUIBridge.h"

#include <string>

namespace IosGameBridge {

void Initialize();
void Shutdown();

IosUIBridge::IHostBackend& Backend();

} // namespace IosGameBridge
