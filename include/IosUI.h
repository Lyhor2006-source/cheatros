#pragma once

#include "IosUIBridge.h"
#include "imgui.h"

namespace Aimbot {
void DrawFovCircle(ImDrawList* draw, ImVec2 center);
}

namespace IosUI {

void SetHeaderTitleFont(ImFont* font);
void PushToast(const char* text);

void ApplyTheme();
void RenderFrame();
void RenderMainMenu();
void RenderEspOverlay(ImDrawList* draw, ImVec2 displaySize);
void RenderEdgeArrow(ImDrawList* draw, ImVec2 displaySize, float angleRad, bool isBot, float distMeters);
void RenderDynamicIsland(ImDrawList* draw, ImVec2 displaySize, int players, int bots);
void RenderFloatingHUD();

void RenderEspTab();
void RenderAimTab();
void RenderMemoryTab();
void RenderTeleportTab();
void RenderHandTab();
void RenderSettingsTab();

void BeginCard(const char* id, const char* title, int iconId, bool accentBorder);
void EndCard();
bool ToggleSwitch(const char* label, bool* value, const char* badgeText, ImU32 badgeColor);
bool LabeledCombo(const char* label, const char* id, int* current, const char* const items[], int count);
bool LabeledSlider(const char* id, const char* label, float* value, float minVal, float maxVal, const char* fmt);
void DrawBadgeBox(ImDrawList* draw, ImVec2 minPt, ImVec2 maxPt, bool active, ImU32 accentColor);
void DrawVectorIcon(ImDrawList* draw, int iconId, ImVec2 center, ImU32 color, float size);
void DrawBrandOrSpecialWidget(ImDrawList* draw, int iconId, ImVec2 pos);

void RenderFeatureRow(IosUIBridge::MemoryFeature feature, const char* customLabel = nullptr);
void RenderFeatureToggle(const char* label, bool* localState, IosUIBridge::MemoryFeature feature);
void RenderItemPicker();
void RenderPlayerLock();

void HandleMenuDrag(bool* menuOpen, ImVec2* pos, float screenW, float screenH);
void HandleWindowDrag(ImVec2 windowSize, bool isHeader, bool allowDrag, ImVec2* pos, float screenW, float screenH, bool clamped);
void HandleFingerScroll(float* lastScrollY, bool* draggingScroll, bool allow);

bool IsPointInMenuOrFloatingHUD(float x, float y, float viewW, float viewH);
void OnTouchBegan(float x, float y, float viewW, float viewH);
void OnTouchMoved(float x, float y, float viewW, float viewH);
void OnTouchEnded(float x, float y, float viewW, float viewH);
void OnTouchCancelled();

} // namespace IosUI
