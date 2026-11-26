#pragma once

#include "IosUIBridge.h"

#include <cstdint>
#include <vector>

namespace MemoryCheats {

void Initialize();
void Shutdown();

IosUIBridge::FeatureStatus GetStatus(IosUIBridge::MemoryFeature feature);
bool RequestFeature(IosUIBridge::MemoryFeature feature, bool enable, float param = 1.0f);
const char* GetFeatureName(IosUIBridge::MemoryFeature feature);

void SetSpeedMultiplier(float multiplier);
float GetSpeedMultiplier();

bool GetFlyEnabled();
void SetFlyEnabled(bool enabled);

bool GetUndergroundEnabled();
void SetUndergroundEnabled(bool enabled);

// Called periodically on tick to keep frozen values active and refresh patch states
void Tick();

std::string GetDiagnosticsSummary();

} // namespace MemoryCheats
