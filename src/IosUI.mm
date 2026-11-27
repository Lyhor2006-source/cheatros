#import "IosUI.h"
#import "MemoryCheats.h"
#import <Foundation/Foundation.h>

#include "imgui_internal.h"
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace IosUIBridge {
UiContext& GetContext() {
    static UiContext gCtx;
    return gCtx;
}
} // namespace IosUIBridge

namespace Aimbot {

void DrawFovCircle(ImDrawList* draw, ImVec2 center) {
    if (!draw) return;
    const auto& aim = IosUIBridge::GetContext().aim;
    if (!aim.masterAim || !aim.showFovCircle) return;

    float r = aim.fovRadiusPx;
    draw->AddCircle(center, r, IM_COL32(155, 95, 255, 24), 128, 7.0f);
    draw->AddCircle(center, r, IM_COL32(169, 112, 255, 235), 128, 1.8f);
    draw->AddCircle(center, std::max(r - 2.0f, 1.0f), IM_COL32(215, 187, 255, 45), 128, 0.8f);
}

} // namespace Aimbot

namespace IosUI {

static ImFont* gHeaderTitleFont = nullptr;
static ImDrawListSplitter gCardSplitter;
static int gDraggedHudKind = -1;   // 0=menu, 1=island, 2=autofire, 3=hidemenu, 10..13=feature, 20..24=tp
static ImVec2 gDragTouchStart(0, 0);
static ImVec2 gDragOrigPos(0, 0);
static bool gDragMoved = false;

void SetHeaderTitleFont(ImFont* font) {
    gHeaderTitleFont = font;
}

void PushToast(const char* text) {
    auto& ctx = IosUIBridge::GetContext();
    ctx.toastText = text ? text : "";
    ctx.toastStartTime = ImGui::GetCurrentContext() ? ImGui::GetTime() : 0.0;
}

static NSString* GetSettingsPlistPath() {
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString* dir = [paths firstObject];
    if (!dir) return nil;
    return [dir stringByAppendingPathComponent:@"ryomenx_settings.plist"];
}

void SaveSettings() {
    auto& ctx = IosUIBridge::GetContext();
    const auto& esp = ctx.esp;
    const auto& aim = ctx.aim;
    const auto& layout = ctx.layout;

    NSMutableDictionary* dict = [NSMutableDictionary dictionaryWithCapacity:64];

    // ESP settings
    dict[@"esp"] = @(esp.masterEsp);
    dict[@"style"] = @(esp.style);
    dict[@"box_style"] = @(esp.boxStyle);
    dict[@"box"] = @(esp.boxes);
    dict[@"skeleton"] = @(esp.skeleton);
    dict[@"health"] = @(esp.health);
    dict[@"name"] = @(esp.name);
    dict[@"team"] = @(esp.teamId);
    dict[@"player_id"] = @(esp.playerId);
    dict[@"distance"] = @(esp.distance);
    dict[@"edge"] = @(esp.edgeArrows);
    dict[@"filter_bots"] = @(esp.hideBots);
    dict[@"lines"] = @(esp.snaplines);
    dict[@"line_origin"] = @(esp.snaplineOrigin);
    dict[@"esp_range"] = @(esp.espRangeMeters);

    // Layout settings
    dict[@"scale"] = @(layout.uiScale);
    dict[@"crosshair"] = @(layout.crosshair);
    dict[@"watermark"] = @(layout.watermark);
    dict[@"hide_record"] = @(layout.hideRecording);
    dict[@"panel_x"] = @(layout.menuPosX);
    dict[@"panel_y"] = @(layout.menuPosY);
    dict[@"panel_width"] = @(layout.menuWidth);
    dict[@"panel_height"] = @(layout.menuHeight);
    dict[@"ipad_view"] = @(esp.ipadView);
    dict[@"ipad_fov"] = @(esp.cameraFovDeg);
    dict[@"vip_float_features"] = @(layout.showFeatureIcons);
    dict[@"vip_float_teleport"] = @(layout.showTeleportIcons);
    dict[@"memory_speed"] = @(layout.speedMultiplier);

    // Aim settings
    dict[@"auto_fire"] = @(aim.autoFire);
    dict[@"aim"] = @(aim.masterAim);
    dict[@"bone"] = @(aim.targetBone);
    dict[@"fov"] = @(aim.fovRadiusPx);
    dict[@"aim_range"] = @(aim.aimRangeMeters);
    dict[@"silent"] = @(aim.silentAim);
    dict[@"silent360"] = @(aim.silent360);
    dict[@"visible"] = @(aim.visibleCheck);
    dict[@"ignore_knocked"] = @(aim.ignoreKnocked);
    dict[@"instant"] = @(aim.instantAim);
    dict[@"trigger"] = @(aim.triggerMode);
    dict[@"silent_range"] = @(aim.silentDistMeters);
    dict[@"power"] = @(aim.aimPower);
    dict[@"aim_bots"] = @(aim.targetBots);
    dict[@"fov_circle"] = @(aim.showFovCircle);
    dict[@"smooth"] = @(aim.smoothness);

    // Note: Memory features are strictly session-only (never persisted; always default OFF on app launch)

    NSUserDefaults* defs = [NSUserDefaults standardUserDefaults];
    [defs setObject:dict forKey:@"RyomenX.Settings.v1"];
    [defs synchronize];

    NSString* filePath = GetSettingsPlistPath();
    if (filePath) {
        [dict writeToFile:filePath atomically:YES];
    }
}

void LoadSettings() {
    NSDictionary* dict = nil;
    NSString* filePath = GetSettingsPlistPath();
    if (filePath && [[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        dict = [NSDictionary dictionaryWithContentsOfFile:filePath];
    }
    if (!dict) {
        NSUserDefaults* defs = [NSUserDefaults standardUserDefaults];
        dict = [defs dictionaryForKey:@"RyomenX.Settings.v1"];
    }
    if (!dict) return;

    auto& ctx = IosUIBridge::GetContext();
    auto& esp = ctx.esp;
    auto& aim = ctx.aim;
    auto& layout = ctx.layout;

    auto readBool = [&](NSString* k, bool& out) {
        id v = dict[k];
        if (v && [v respondsToSelector:@selector(boolValue)]) out = [v boolValue];
    };
    auto readInt = [&](NSString* k, int& out) {
        id v = dict[k];
        if (v && [v respondsToSelector:@selector(intValue)]) out = [v intValue];
    };
    auto readFloat = [&](NSString* k, float& out) {
        id v = dict[k];
        if (v && [v respondsToSelector:@selector(floatValue)]) out = [v floatValue];
    };

    readBool(@"esp", esp.masterEsp);
    readInt(@"style", esp.style);
    readInt(@"box_style", esp.boxStyle);
    readBool(@"box", esp.boxes);
    readBool(@"skeleton", esp.skeleton);
    readBool(@"health", esp.health);
    readBool(@"name", esp.name);
    readBool(@"team", esp.teamId);
    readBool(@"player_id", esp.playerId);
    readBool(@"distance", esp.distance);
    readBool(@"edge", esp.edgeArrows);
    readBool(@"filter_bots", esp.hideBots);
    readBool(@"lines", esp.snaplines);
    readInt(@"line_origin", esp.snaplineOrigin);
    readFloat(@"esp_range", esp.espRangeMeters);

    readFloat(@"scale", layout.uiScale);
    readBool(@"crosshair", layout.crosshair);
    readBool(@"watermark", layout.watermark);
    readBool(@"hide_record", layout.hideRecording);
    readFloat(@"panel_x", layout.menuPosX);
    readFloat(@"panel_y", layout.menuPosY);
    readFloat(@"panel_width", layout.menuWidth);
    readFloat(@"panel_height", layout.menuHeight);
    readBool(@"ipad_view", esp.ipadView);
    readFloat(@"ipad_fov", esp.cameraFovDeg);
    readBool(@"vip_float_features", layout.showFeatureIcons);
    readBool(@"vip_float_teleport", layout.showTeleportIcons);
    readFloat(@"memory_speed", layout.speedMultiplier);

    readBool(@"auto_fire", aim.autoFire);
    readBool(@"aim", aim.masterAim);
    readInt(@"bone", aim.targetBone);
    readFloat(@"fov", aim.fovRadiusPx);
    readFloat(@"aim_range", aim.aimRangeMeters);
    readBool(@"silent", aim.silentAim);
    readBool(@"silent360", aim.silent360);
    readBool(@"visible", aim.visibleCheck);
    readBool(@"ignore_knocked", aim.ignoreKnocked);
    readBool(@"instant", aim.instantAim);
    readInt(@"trigger", aim.triggerMode);
    readFloat(@"silent_range", aim.silentDistMeters);
    readFloat(@"power", aim.aimPower);
    readBool(@"aim_bots", aim.targetBots);
    readBool(@"fov_circle", aim.showFovCircle);
    readFloat(@"smooth", aim.smoothness);

    if (esp.masterEsp || aim.masterAim) {
        layout.engineStarted = true;
    }

    // Memory features intentionally not restored (always default OFF on game launch)

    if (ctx.backend) {
        if (layout.engineStarted) {
            ctx.backend->SetEngineEnabled(true);
        }
        ctx.backend->SetSpeedMultiplier(layout.speedMultiplier);
        if (esp.ipadView) {
            ctx.backend->SetIpadView(true, esp.cameraFovDeg);
        }
    }
}

static ImVec2 ResolveSlotPos(ImVec2 storedPos, ImVec2 fallbackPos, float viewW, float viewH, float w, float h) {
    if (storedPos.x >= 0.0f && storedPos.y >= 0.0f) {
        return ImVec2(
            std::clamp(storedPos.x, 4.0f, std::max(4.0f, viewW - w - 4.0f)),
            std::clamp(storedPos.y, 4.0f, std::max(4.0f, viewH - h - 4.0f)));
    }
    return fallbackPos;
}

static ImVec2 GetFeatureIconPos(int idx, float viewW, float viewH) {
    auto& layout = IosUIBridge::GetContext().layout;
    ImVec2 defPos(18.0f, 70.0f + idx * 42.0f);
    return ResolveSlotPos(ImVec2(layout.featurePos[idx][0], layout.featurePos[idx][1]),
                          defPos, viewW, viewH, 94.0f, 30.0f);
}

static ImVec2 GetIslandPos(float width, float height, float viewW, float viewH) {
    auto& layout = IosUIBridge::GetContext().layout;
    ImVec2 defPos((viewW - width) * 0.5f, 10.0f);
    return ResolveSlotPos(ImVec2(layout.islandPosX, layout.islandPosY),
                          defPos, viewW, viewH, width, height);
}

static ImRect GetIslandTouchRect(float viewW, float viewH) {
    const auto& layout = IosUIBridge::GetContext().layout;
    if (layout.hubBackdropActive) {
        return ImRect(layout.hubBackdropX, layout.hubBackdropY,
                      layout.hubBackdropX + layout.hubBackdropW,
                      layout.hubBackdropY + layout.hubBackdropH);
    }
    const ImVec2 origin = GetIslandPos(114.0f, 30.0f, viewW, viewH);
    return ImRect(origin.x, origin.y, origin.x + 114.0f, origin.y + 30.0f);
}

static bool RectContains(ImVec2 origin, float w, float h, float px, float py) {
    return px >= origin.x && px <= (origin.x + w) && py >= origin.y && py <= (origin.y + h);
}

void ApplyTheme() {
    ImGuiStyle& s = ImGui::GetStyle();
    s.WindowPadding = ImVec2(12.0f, 8.0f);
    s.WindowRounding = 18.0f;
    s.WindowBorderSize = 1.0f;
    s.ChildRounding = 10.0f;
    s.ChildBorderSize = 0.0f;
    s.PopupRounding = 10.0f;
    s.PopupBorderSize = 1.0f;
    s.FramePadding = ImVec2(10.0f, 8.0f);
    s.FrameRounding = 7.0f;
    s.FrameBorderSize = 0.0f;
    s.ItemSpacing = ImVec2(8.0f, 4.0f);
    s.ScrollbarSize = 8.0f;
    s.ScrollbarRounding = 8.0f;
    s.GrabRounding = 6.0f;

    ImVec4* c = s.Colors;
    c[ImGuiCol_Text]                 = ImVec4(0.91f, 0.93f, 0.97f, 1.00f);
    c[ImGuiCol_TextDisabled]         = ImVec4(0.53f, 0.58f, 0.67f, 1.00f);
    c[ImGuiCol_WindowBg]             = ImVec4(0.035f, 0.05f, 0.075f, 0.22f);
    c[ImGuiCol_ChildBg]              = ImVec4(0.00f, 0.00f, 0.00f, 0.00f);
    c[ImGuiCol_PopupBg]              = ImVec4(0.10f, 0.12f, 0.16f, 0.99f);
    c[ImGuiCol_Border]               = ImVec4(0.78f, 0.85f, 0.96f, 0.24f);
    c[ImGuiCol_BorderShadow]         = ImVec4(0.00f, 0.00f, 0.00f, 0.15f);
    c[ImGuiCol_FrameBg]              = ImVec4(0.04f, 0.06f, 0.09f, 0.42f);
    c[ImGuiCol_FrameBgHovered]       = ImVec4(0.22f, 0.26f, 0.32f, 0.60f);
    c[ImGuiCol_FrameBgActive]        = ImVec4(0.25f, 0.29f, 0.36f, 0.68f);
    c[ImGuiCol_TitleBg]              = c[ImGuiCol_WindowBg];
    c[ImGuiCol_TitleBgActive]        = c[ImGuiCol_WindowBg];
    c[ImGuiCol_ScrollbarBg]          = ImVec4(0.04f, 0.05f, 0.07f, 0.12f);
    c[ImGuiCol_ScrollbarGrab]        = ImVec4(0.30f, 0.34f, 0.42f, 0.90f);
    c[ImGuiCol_ScrollbarGrabHovered] = ImVec4(0.20f, 0.51f, 0.56f, 1.00f);
    c[ImGuiCol_ScrollbarGrabActive]  = ImVec4(0.27f, 0.73f, 0.75f, 1.00f);
    c[ImGuiCol_CheckMark]            = ImVec4(0.28f, 0.87f, 0.88f, 1.00f);
    c[ImGuiCol_SliderGrab]           = ImVec4(0.22f, 0.78f, 0.81f, 1.00f);
    c[ImGuiCol_SliderGrabActive]     = ImVec4(0.59f, 0.98f, 0.95f, 1.00f);
    c[ImGuiCol_Button]               = ImVec4(0.72f, 0.80f, 0.92f, 0.12f);
    c[ImGuiCol_ButtonHovered]        = ImVec4(0.72f, 0.78f, 0.88f, 0.22f);
    c[ImGuiCol_ButtonActive]         = ImVec4(0.16f, 0.69f, 0.72f, 0.32f);
    c[ImGuiCol_Header]               = ImVec4(0.08f, 0.26f, 0.30f, 1.00f);
    c[ImGuiCol_HeaderHovered]        = ImVec4(0.10f, 0.38f, 0.42f, 1.00f);
    c[ImGuiCol_HeaderActive]         = ImVec4(0.12f, 0.48f, 0.51f, 1.00f);
    c[ImGuiCol_Separator]            = ImVec4(0.23f, 0.26f, 0.32f, 0.80f);
}

void DrawBadgeBox(ImDrawList* draw, ImVec2 minPt, ImVec2 maxPt, bool active, ImU32 accentColor) {
    if (!draw) return;
    draw->AddRectFilled(
        ImVec2(minPt.x + 1.0f, minPt.y + 2.0f),
        ImVec2(maxPt.x + 1.0f, maxPt.y + 2.0f),
        IM_COL32(0, 0, 0, 75), 11.0f);
    draw->AddRectFilled(minPt, maxPt, IM_COL32(17, 26, 39, 235), 11.0f);
    if (active) {
        draw->AddRectFilled(minPt, maxPt, (accentColor & 0x00FFFFFF) | 0x22000000, 11.0f);
    }
    draw->AddRect(minPt, maxPt, active ? accentColor : IM_COL32(95, 110, 130, 130), 11.0f, 0, 1.2f);
    draw->AddLine(
        ImVec2(minPt.x + 10.0f, minPt.y + 1.5f),
        ImVec2(maxPt.x - 10.0f, minPt.y + 1.5f),
        IM_COL32(240, 209, 143, 65), 0.8f);
}

void DrawVectorIcon(ImDrawList* draw, int iconId, ImVec2 center, ImU32 color, float size) {
    if (!draw) return;
    float s = size / 24.0f;
    float cx = center.x;
    float cy = center.y;
    auto pt = [&](float x, float y) { return ImVec2(cx + x * s, cy + y * s); };

    switch (iconId) {
        case 0: // Player / Enemy person icon
        case 3: {
            draw->AddCircle(pt(0.0f, -5.0f), 3.3f * s, color, 20, 1.8f * s);
            draw->PathClear();
            draw->PathArcTo(pt(0.0f, 8.0f), 7.5f * s, 3.1415926f, 6.283185f, 16);
            draw->PathStroke(color, 0, 1.8f * s);
            break;
        }
        case 1: { // Bot / Robot icon
            draw->AddRect(pt(-7.0f, -4.0f), pt(7.0f, 7.0f), color, 2.5f * s, 0, 1.7f * s);
            draw->AddLine(pt(0.0f, -4.0f), pt(0.0f, -9.0f), color, 1.65f * s);
            draw->AddCircleFilled(pt(0.0f, -10.0f), 1.4f * s, color, 12);
            draw->AddCircleFilled(pt(-3.0f, -0.5f), 1.4f * s, color, 12);
            draw->AddCircleFilled(pt(3.0f, -0.5f), 1.4f * s, color, 12);
            draw->AddLine(pt(-3.0f, 4.0f), pt(3.0f, 4.0f), color, 1.65f * s);
            break;
        }
        case 2: { // Save pin / compass point
            draw->PathClear();
            draw->PathArcTo(pt(0.0f, 0.0f), 7.0f * s, 0.0f, 6.283185f, 20);
            draw->PathStroke(color, ImDrawFlags_Closed, 1.65f * s);
            draw->AddCircleFilled(pt(0.0f, 0.0f), 2.5f * s, color, 12);
            draw->AddLine(pt(0.0f, -11.0f), pt(0.0f, -7.0f), color, 1.65f * s);
            draw->AddLine(pt(0.0f, 7.0f), pt(0.0f, 11.0f), color, 1.65f * s);
            draw->AddLine(pt(-11.0f, 0.0f), pt(-7.0f, 0.0f), color, 1.65f * s);
            draw->AddLine(pt(7.0f, 0.0f), pt(11.0f, 0.0f), color, 1.65f * s);
            break;
        }
        case 4: { // Airplane icon
            ImVec2 poly[] = {
                pt(0.0f, -10.0f), pt(2.0f, -3.0f), pt(9.0f, 2.0f),
                pt(2.0f, 2.0f), pt(3.0f, 8.0f), pt(-3.0f, 8.0f),
                pt(-2.0f, 2.0f), pt(-9.0f, 2.0f), pt(-2.0f, -3.0f)
            };
            draw->AddPolyline(poly, 9, color, ImDrawFlags_Closed, 1.7f * s);
            break;
        }
        case 5: { // Isometric crate / Item icon
            ImVec2 hex[] = {
                pt(0.0f, -10.0f), pt(9.0f, -5.0f), pt(9.0f, 5.0f),
                pt(0.0f, 10.0f), pt(-9.0f, 5.0f), pt(-9.0f, -5.0f)
            };
            draw->AddPolyline(hex, 6, color, ImDrawFlags_Closed, 1.65f * s);
            draw->AddLine(pt(-9.0f, -5.0f), pt(0.0f, 0.0f), color, 1.65f * s);
            draw->AddLine(pt(9.0f, -5.0f), pt(0.0f, 0.0f), color, 1.65f * s);
            draw->AddLine(pt(0.0f, 0.0f), pt(0.0f, 10.0f), color, 1.65f * s);
            draw->AddLine(pt(-4.5f, -7.5f), pt(4.5f, -2.5f), color, 1.65f * s);
            break;
        }
        case 6: // AutoFire / Chevron Right
        case 7: { // HideMenu / Chevron Left
            float dir = (iconId == 6) ? 1.0f : -1.0f;
            float t = 1.65f * s;
            draw->AddLine(pt(-6.5f, dir * -0.5f), pt(0.0f, dir * -6.5f), color, t);
            draw->AddLine(pt(0.0f, dir * -6.5f), pt(6.5f, dir * -0.5f), color, t);
            draw->AddLine(pt(-6.5f, dir * 7.5f), pt(0.0f, dir * 1.5f), color, t);
            draw->AddLine(pt(0.0f, dir * 1.5f), pt(6.5f, dir * 7.5f), color, t);
            break;
        }
        case 8: { // Crosshair / Target Teleport
            draw->AddCircle(pt(0.0f, 0.0f), 8.0f * s, color, 28, 1.6f * s);
            draw->AddLine(pt(-11.0f, 0.0f), pt(11.0f, 0.0f), color, 1.65f * s);
            draw->AddLine(pt(0.0f, -11.0f), pt(0.0f, 11.0f), color, 1.65f * s);
            break;
        }
        case 9: { // Fast Move lightning bolt
            ImVec2 bolt[] = {
                pt(2.0f, -10.0f), pt(-6.0f, 1.0f), pt(-1.0f, 1.0f),
                pt(-3.0f, 10.0f), pt(7.0f, -3.0f), pt(1.0f, -3.0f)
            };
            draw->AddPolyline(bolt, 6, color, ImDrawFlags_Closed, 1.8f * s);
            draw->AddLine(pt(-11.0f, -5.0f), pt(-6.0f, -5.0f), color, 1.65f * s);
            draw->AddLine(pt(6.0f, 6.0f), pt(11.0f, 6.0f), color, 1.65f * s);
            break;
        }
        case 10: { // No Fall icon
            draw->PathClear();
            draw->PathArcTo(pt(0.0f, -1.0f), 9.0f * s, 0.0f, 6.283185f, 20);
            draw->PathStroke(color, 0, 1.8f * s);
            draw->AddLine(pt(-3.0f, 7.0f), pt(3.0f, 7.0f), color, 1.65f * s);
            draw->AddLine(pt(-10.0f, 10.0f), pt(10.0f, 10.0f), color, 1.65f * s);
            break;
        }
        case 11: { // Wallhack grid icon
            draw->AddRect(pt(-9.0f, -8.0f), pt(9.0f, 8.0f), color, 1.5f * s, 0, 1.7f * s);
            draw->AddLine(pt(-9.0f, -2.0f), pt(9.0f, -2.0f), color, 1.65f * s);
            draw->AddLine(pt(-9.0f, 3.0f), pt(9.0f, 3.0f), color, 1.65f * s);
            draw->AddLine(pt(0.0f, -8.0f), pt(0.0f, -2.0f), color, 1.65f * s);
            draw->AddLine(pt(-3.0f, -2.0f), pt(-3.0f, 3.0f), color, 1.65f * s);
            draw->AddLine(pt(3.0f, -2.0f), pt(3.0f, 3.0f), color, 1.65f * s);
            break;
        }
        case 12: { // Fly / Wing icon
            draw->AddLine(pt(0.0f, -9.0f), pt(-9.0f, 4.0f), color, 1.65f * s);
            draw->AddLine(pt(0.0f, -9.0f), pt(9.0f, 4.0f), color, 1.65f * s);
            draw->AddLine(pt(-4.0f, 0.0f), pt(4.0f, 0.0f), color, 1.65f * s);
            draw->AddLine(pt(-3.0f, -10.0f), pt(3.0f, -10.0f), color, 1.65f * s);
            draw->AddLine(pt(-2.0f, 8.0f), pt(2.0f, 8.0f), color, 1.65f * s);
            break;
        }
        case 13: { // Crown / Brand Header Emblem
            ImVec2 crown[] = {
                pt(-10.0f, -5.0f), pt(-6.0f, -2.0f), pt(-2.0f, -5.0f),
                pt(0.0f, 5.0f), pt(5.0f, -5.0f), pt(10.0f, -5.0f), pt(7.0f, 5.0f)
            };
            draw->AddPolyline(crown, 7, color, ImDrawFlags_Closed, 1.7f * s);
            break;
        }
        default: {
            draw->AddCircle(pt(0.0f, 0.0f), 6.0f * s, color, 16, 1.6f * s);
            break;
        }
    }
}

void DrawBrandOrSpecialWidget(ImDrawList* draw, int iconId, ImVec2 pos) {
    if (!draw) return;
    ImU32 cyan = IM_COL32(70, 221, 225, 255);
    switch (iconId) {
        case 0: // Radar / eye dot
            draw->AddCircleFilled(pos, 2.8f, cyan, 16);
            draw->AddCircle(pos, 5.5f, cyan, 16, 1.3f);
            break;
        case 1: // Color gradient bar emblem
            draw->AddRectFilled(ImVec2(pos.x - 5.5f, pos.y - 3.5f), ImVec2(pos.x + 5.5f, pos.y + 3.5f), cyan, 2.5f);
            break;
        case 2: // Palette / Display prism
            draw->AddRectFilledMultiColor(
                ImVec2(pos.x - 5.5f, pos.y - 4.5f),
                ImVec2(pos.x + 5.5f, pos.y + 4.5f),
                IM_COL32(255, 220, 155, 255),
                IM_COL32(145, 106, 52, 255),
                cyan,
                IM_COL32(55, 26, 144, 192));
            break;
        case 3: // Hex cluster
            draw->AddCircleFilled(pos, 5.0f, cyan, 16);
            draw->AddCircleFilled(pos, 2.2f, IM_COL32(12, 10, 12, 255), 12);
            break;
        case 4: // Crosshair mini
            draw->AddCircle(pos, 4.5f, cyan, 16, 1.2f);
            draw->AddCircleFilled(pos, 1.5f, cyan, 8);
            draw->AddLine(ImVec2(pos.x - 6.5f, pos.y), ImVec2(pos.x - 2.5f, pos.y), cyan, 1.2f);
            draw->AddLine(ImVec2(pos.x + 2.5f, pos.y), ImVec2(pos.x + 6.5f, pos.y), cyan, 1.2f);
            break;
        default: // Triangle / Speed arrow
            draw->AddTriangleFilled(
                ImVec2(pos.x - 7.0f, pos.y + 5.0f),
                ImVec2(pos.x + 7.0f, pos.y + 5.0f),
                ImVec2(pos.x, pos.y - 5.0f),
                cyan);
            break;
    }
}

void BeginCard(const char* id, const char* title, int iconId, bool accentBorder) {
    (void)accentBorder;
    float availW = ImGui::GetContentRegionAvail().x;
    ImGui::PushID(id);
    ImGui::BeginGroup();

    ImDrawList* dl = ImGui::GetWindowDrawList();
    gCardSplitter.Split(dl, 2);
    gCardSplitter.SetCurrentChannel(dl, 1);

    ImGui::Dummy(ImVec2(0.0f, 2.0f));
    ImGui::Indent(8.0f);
    ImGui::PushTextWrapPos(ImGui::GetCursorPosX() + std::max(availW - 16.0f, 1.0f));
    ImGui::PushItemWidth(std::max(availW - 16.0f, 1.0f));
    ImGui::BeginGroup();

    ImVec2 p = ImGui::GetCursorScreenPos();
    DrawBrandOrSpecialWidget(dl, iconId, ImVec2(p.x + 8.0f, p.y + 8.0f));
    ImGui::SetCursorPosX(ImGui::GetCursorPosX() + 20.0f);
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.70f, 0.76f, 0.86f, 1.0f));
    ImGui::TextUnformatted(title);
    ImGui::PopStyleColor(1);
    ImGui::Dummy(ImVec2(0.0f, 2.0f));
}

void EndCard() {
    ImGui::EndGroup();
    ImGui::PopItemWidth();
    ImGui::PopTextWrapPos();
    ImGui::Unindent(8.0f);
    ImGui::Dummy(ImVec2(0.0f, 2.0f));
    ImGui::EndGroup();

    ImVec2 mn = ImGui::GetItemRectMin();
    ImVec2 mx = ImGui::GetItemRectMax();
    ImDrawList* dl = ImGui::GetWindowDrawList();
    gCardSplitter.SetCurrentChannel(dl, 0);
    dl->AddRectFilled(mn, mx, IM_COL32(228, 238, 255, 17), 10.0f);
    dl->AddRect(mn, mx, IM_COL32(216, 232, 255, 46), 10.0f, 0, 1.0f);
    dl->AddLine(ImVec2(mn.x + 11.0f, mn.y + 1.0f), ImVec2(mx.x - 11.0f, mn.y + 1.0f), 0x20FFFFFF, 1.0f);
    gCardSplitter.Merge(dl);
    ImGui::PopID();
    ImGui::Spacing();
}

bool ToggleSwitch(const char* label, bool* value, const char* badgeText, ImU32 badgeColor) {
    ImVec2 pos = ImGui::GetCursorScreenPos();
    float availW = std::max(ImGui::GetContentRegionAvail().x, 1.0f);
    float pillW = 40.0f;
    float pillH = 20.0f;
    float wrapW = std::max(availW - 50.0f, 24.0f);

    ImFont* font = ImGui::GetFont();
    float fontSz = ImGui::GetFontSize();
    ImVec2 txtSz = font->CalcTextSizeA(fontSz, FLT_MAX, wrapW, label);
    float rowH = std::max(txtSz.y + 10.0f, 34.0f);

    ImGui::PushID(label);
    bool pressed = ImGui::InvisibleButton("##switch", ImVec2(availW, rowH));
    if (pressed && value) {
        *value = !(*value);
        PushToast((*value) ? (std::string(label) + " ON").c_str() : (std::string(label) + " OFF").c_str());
        SaveSettings();
    }

    bool hovered = ImGui::IsItemHovered();
    ImDrawList* dl = ImGui::GetWindowDrawList();
    ImVec2 rowMax(pos.x + availW, pos.y + rowH);
    if (hovered) {
        dl->AddRectFilled(pos, rowMax, IM_COL32(70, 221, 225, 16), 5.0f);
    }

    float textY = pos.y + (rowH - txtSz.y) * 0.5f;
    dl->AddText(font, fontSz, ImVec2(pos.x + 4.0f, textY), IM_COL32(231, 235, 243, 255), label, nullptr, wrapW);
    if (badgeText && badgeText[0]) {
        dl->AddText(font, fontSz * 0.85f, ImVec2(pos.x + 8.0f + txtSz.x, textY + 1.0f), badgeColor, badgeText);
    }

    bool on = (value && *value);
    ImVec2 trackMin(rowMax.x - pillW - 4.0f, pos.y + (rowH - pillH) * 0.5f);
    ImVec2 trackMax(trackMin.x + pillW, trackMin.y + pillH);
    dl->AddRectFilled(
        trackMin, trackMax,
        on ? IM_COL32(70, 221, 225, 255) : IM_COL32(57, 65, 81, 255),
        10.0f);

    float knobX = on ? (trackMax.x - 10.0f) : (trackMin.x + 10.0f);
    float knobY = trackMin.y + pillH * 0.5f;
    dl->AddCircleFilled(
        ImVec2(knobX, knobY), 7.5f,
        on ? IM_COL32(239, 255, 254, 255) : IM_COL32(164, 174, 192, 255),
        20);

    ImGui::PopID();
    return pressed;
}

bool LabeledCombo(const char* label, const char* id, int* current, const char* const items[], int count) {
    ImGui::TextUnformatted(label);
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 5.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(8.0f, 5.0f));
    ImGui::PushStyleColor(ImGuiCol_FrameBg, ImVec4(0.04f, 0.06f, 0.09f, 0.42f));
    ImGui::PushStyleColor(ImGuiCol_FrameBgHovered, ImVec4(0.17f, 0.20f, 0.26f, 0.65f));
    ImGui::PushStyleColor(ImGuiCol_Border, ImVec4(0.27f, 0.31f, 0.40f, 0.85f));
    ImGui::PushStyleColor(ImGuiCol_PopupBg, ImVec4(0.10f, 0.12f, 0.16f, 0.99f));
    ImGui::PushStyleColor(ImGuiCol_Header, ImVec4(0.08f, 0.32f, 0.36f, 0.75f));
    ImGui::PushStyleColor(ImGuiCol_HeaderHovered, ImVec4(0.10f, 0.44f, 0.47f, 0.95f));

    ImGui::SetNextItemWidth(std::max(ImGui::GetContentRegionAvail().x - 4.0f, 1.0f));
    const char* preview = (*current >= 0 && *current < count) ? items[*current] : "";
    bool changed = false;
    if (ImGui::BeginCombo(id, preview)) {
        for (int i = 0; i < count; ++i) {
            bool selected = (*current == i);
            if (ImGui::Selectable(items[i], selected)) {
                *current = i;
                changed = true;
                SaveSettings();
            }
            if (selected) {
                ImGui::SetItemDefaultFocus();
            }
        }
        ImGui::EndCombo();
    }

    ImGui::PopStyleColor(6);
    ImGui::PopStyleVar(2);
    ImGui::Spacing();
    return changed;
}

bool LabeledSlider(const char* id, const char* label, float* value, float minVal, float maxVal, const char* fmt) {
    ImVec2 p = ImGui::GetCursorScreenPos();
    float availW = std::max(ImGui::GetContentRegionAvail().x - 4.0f, 1.0f);
    ImGui::TextUnformatted(label);

    ImVec2 trackOrigin = ImGui::GetCursorScreenPos();
    float trackW = std::max(ImGui::GetContentRegionAvail().x - 4.0f, 1.0f);
    ImGui::PushID(id);
    ImGui::InvisibleButton("##slider", ImVec2(trackW, 26.0f));

    ImGuiID sliderID = ImGui::GetID("##slider");
    static ImGuiID sActiveSliderID = 0;
    static ImVec2 sDragStartPos(0.0f, 0.0f);
    static bool sSliderHasDragged = false;

    if (ImGui::IsItemActivated()) {
        sActiveSliderID = sliderID;
        sDragStartPos = ImGui::GetIO().MousePos;
        sSliderHasDragged = false;
    }

    if (ImGui::IsItemActive() && sActiveSliderID == sliderID) {
        ImVec2 curPos = ImGui::GetIO().MousePos;
        float dx = std::fabs(curPos.x - sDragStartPos.x);
        float dy = std::fabs(curPos.y - sDragStartPos.y);
        // Do not jump on touch. Require intentional horizontal drag (dx > 8.0f and dx > dy * 1.15f)
        if (dx > 8.0f && dx > dy * 1.15f) {
            sSliderHasDragged = true;
        }
    } else if (sActiveSliderID == sliderID) {
        sActiveSliderID = 0;
        sSliderHasDragged = false;
    }

    bool changed = false;
    if (ImGui::IsItemActive() && sActiveSliderID == sliderID && sSliderHasDragged) {
        float mouseX = ImGui::GetIO().MousePos.x;
        float t = std::clamp((mouseX - trackOrigin.x) / trackW, 0.0f, 1.0f);
        float newVal = minVal + t * (maxVal - minVal);
        if (std::fabs(newVal - *value) > 1e-4f) {
            *value = newVal;
            changed = true;
            SaveSettings();
        }
    }

    char buf[32];
    std::snprintf(buf, sizeof(buf), fmt, *value);
    ImVec2 valSz = ImGui::CalcTextSize(buf);
    ImDrawList* dl = ImGui::GetWindowDrawList();
    dl->AddText(ImVec2(p.x + availW - valSz.x, p.y), IM_COL32(70, 221, 225, 255), buf);

    float norm = (maxVal > minVal) ? std::clamp((*value - minVal) / (maxVal - minVal), 0.0f, 1.0f) : 0.0f;
    float cy = trackOrigin.y + 13.0f;
    dl->AddRectFilled(ImVec2(trackOrigin.x, cy - 2.0f), ImVec2(trackOrigin.x + trackW, cy + 2.0f), IM_COL32(56, 64, 80, 255), 2.0f);
    if (norm > 0.0f) {
        dl->AddRectFilled(ImVec2(trackOrigin.x, cy - 2.0f), ImVec2(trackOrigin.x + trackW * norm, cy + 2.0f), IM_COL32(70, 221, 225, 255), 2.0f);
    }
    ImVec2 knobCenter(trackOrigin.x + trackW * norm, cy);
    dl->AddCircleFilled(knobCenter, 6.5f, IM_COL32(70, 221, 225, 255), 16);
    dl->AddCircle(knobCenter, 6.5f, IM_COL32(255, 220, 161, 230), 16, 1.0f);

    ImGui::PopID();
    ImGui::Spacing();
    return changed;
}

void HandleFingerScroll(float* lastScrollY, bool* draggingScroll, bool allow) {
    ImGuiIO& io = ImGui::GetIO();
    if (!allow || !io.MouseDown[0]) {
        *draggingScroll = false;
        return;
    }
    if (!*draggingScroll && ImGui::IsWindowHovered(ImGuiHoveredFlags_AllowWhenBlockedByActiveItem)) {
        *draggingScroll = true;
        *lastScrollY = io.MousePos.y;
    } else if (*draggingScroll) {
        float dy = io.MousePos.y - *lastScrollY;
        *lastScrollY = io.MousePos.y;
        ImGui::SetScrollY(ImGui::GetScrollY() - dy);
    }
}

void HandleWindowDrag(ImVec2 windowSize, bool isHeader, bool allowDrag, ImVec2* pos, float screenW, float screenH, bool clamped) {
    (void)windowSize;
    if (!allowDrag || !isHeader) return;
    ImGuiIO& io = ImGui::GetIO();
    if (io.MouseDown[0] && ImGui::IsWindowHovered(ImGuiHoveredFlags_AllowWhenBlockedByPopup)) {
        pos->x += io.MouseDelta.x;
        pos->y += io.MouseDelta.y;
        if (clamped) {
            pos->x = std::clamp(pos->x, 6.0f, std::max(6.0f, screenW - 40.0f));
            pos->y = std::clamp(pos->y, 6.0f, std::max(6.0f, screenH - 40.0f));
        }
    }
}

void RenderFeatureRow(IosUIBridge::MemoryFeature feature, const char* customLabel) {
    auto* be = IosUIBridge::GetContext().backend;
    IosUIBridge::FeatureStatus st = be ? be->GetMemoryFeatureStatus(feature) : IosUIBridge::FeatureStatus{};
    const char* name = customLabel ? customLabel : (be ? be->GetMemoryFeatureName(feature) : "Feature");

    const char* badge = "Inactive";
    ImU32 badgeCol = IM_COL32(175, 180, 195, 255);
    if (st.pending) {
        badge = "Applying...";
        badgeCol = IM_COL32(255, 198, 107, 255);
    } else if (st.error) {
        badge = "Error";
        badgeCol = IM_COL32(255, 80, 90, 255);
    } else if (st.enabled) {
        badge = "Active";
        badgeCol = IM_COL32(70, 221, 225, 255);
    }

    bool val = st.enabled;
    if (ToggleSwitch(name, &val, badge, badgeCol) && be) {
        const float param = (feature == IosUIBridge::MemoryFeature::SpeedHack)
            ? IosUIBridge::GetContext().layout.speedMultiplier
            : 1.0f;
        bool ok = be->RequestMemoryFeature(feature, val, param);
        if (!ok) {
            PushToast((std::string(name) + ": Request not accepted").c_str());
        } else {
            PushToast((std::string(name) + " requested").c_str());
        }
        SaveSettings();
    }
}

void RenderFeatureToggle(const char* label, bool* localState, IosUIBridge::MemoryFeature feature) {
    auto* be = IosUIBridge::GetContext().backend;
    IosUIBridge::FeatureStatus st = be ? be->GetMemoryFeatureStatus(feature) : IosUIBridge::FeatureStatus{};
    if (be && !st.pending) {
        *localState = st.enabled;
    }
    const char* badge = nullptr;
    ImU32 badgeCol = IM_COL32(175, 180, 195, 255);
    if (st.pending) {
        badge = "Applying...";
        badgeCol = IM_COL32(255, 198, 107, 255);
    } else if (st.error) {
        badge = "Error";
        badgeCol = IM_COL32(255, 80, 90, 255);
    } else if (st.enabled) {
        badge = "Active";
        badgeCol = IM_COL32(70, 221, 225, 255);
    }
    ImGui::BeginDisabled(st.pending);
    if (ToggleSwitch(label, localState, badge, badgeCol) && be) {
        be->RequestMemoryFeature(feature, *localState, 1.0f);
        PushToast((std::string(label) + (*localState ? " requested" : " off")).c_str());
        SaveSettings();
    }
    ImGui::EndDisabled();
}

void RenderEspTab() {
    auto& ctx = IosUIBridge::GetContext();
    auto& esp = ctx.esp;
    float availW = ImGui::GetContentRegionAvail().x;
    int cols = (availW >= 480.0f) ? 2 : 1;

    ImGui::PushStyleVar(ImGuiStyleVar_CellPadding, ImVec2(5.0f, 4.0f));
    if (ImGui::BeginTable("##visuals_grid", cols, ImGuiTableFlags_SizingStretchSame)) {
        ImGui::TableNextColumn();
        BeginCard("##esp_master", "PLAYER ESP", 0, true);
        ToggleSwitch("Master ESP", &esp.masterEsp, nullptr, IM_COL32(175, 180, 195, 255));
        static const char* kStyles[] = {"Presentation: CrownPulse", "Presentation: VideoTrace"};
        LabeledCombo("Style", "##esp_style", &esp.style, kStyles, 2);

        ImVec2 lp = ImGui::GetCursorScreenPos();
        float lw = std::max(ImGui::GetContentRegionAvail().x - 4.0f, 1.0f);
        ImGui::GetWindowDrawList()->AddLine(lp, ImVec2(lp.x + lw, lp.y), IM_COL32(60, 68, 83, 180), 1.0f);
        ImGui::Dummy(ImVec2(lw, 1.0f));

        ToggleSwitch("Boxes", &esp.boxes, nullptr, IM_COL32(175, 180, 195, 255));
        ToggleSwitch("Skeleton", &esp.skeleton, nullptr, IM_COL32(175, 180, 195, 255));
        ToggleSwitch("Health", &esp.health, nullptr, IM_COL32(175, 180, 195, 255));
        ToggleSwitch("Name", &esp.name, nullptr, IM_COL32(175, 180, 195, 255));
        ToggleSwitch("Distance", &esp.distance, nullptr, IM_COL32(175, 180, 195, 255));
        ToggleSwitch("Edge Arrows", &esp.edgeArrows, nullptr, IM_COL32(175, 180, 195, 255));
        ToggleSwitch("Snaplines", &esp.snaplines, nullptr, IM_COL32(175, 180, 195, 255));
        static const char* kOrigins[] = {"Line: Top", "Line: Crosshair", "Line: Bottom", "Line: Count hub"};
        LabeledCombo("Snapline Origin", "##line_origin", &esp.snaplineOrigin, kOrigins, 4);
        ToggleSwitch("Hide Bots", &esp.hideBots, nullptr, IM_COL32(175, 180, 195, 255));
        ToggleSwitch("Team ID", &esp.teamId, nullptr, IM_COL32(175, 180, 195, 255));
        ToggleSwitch("Player ID", &esp.playerId, nullptr, IM_COL32(175, 180, 195, 255));
        EndCard();

        ImGui::TableNextColumn();
        BeginCard("##esp_detail", "DISPLAY", 2, true);
        LabeledSlider("##esp_range", "ESP Range", &esp.espRangeMeters, 50.0f, 3000.0f, "%.0fm");
        static const char* kBoxStyles[] = {"2D Box (Standard)", "Corner Box (Brackets)", "3D Box (Perspective)"};
        LabeledCombo("Box Style", "##box_style", &esp.boxStyle, kBoxStyles, 3);

        ImVec2 lp2 = ImGui::GetCursorScreenPos();
        float lw2 = std::max(ImGui::GetContentRegionAvail().x - 4.0f, 1.0f);
        ImGui::GetWindowDrawList()->AddLine(lp2, ImVec2(lp2.x + lw2, lp2.y), IM_COL32(60, 68, 83, 180), 1.0f);
        ImGui::Dummy(ImVec2(lw2, 1.0f));

        if (ToggleSwitch("iPad View", &esp.ipadView, nullptr, IM_COL32(175, 180, 195, 255)) && ctx.backend) {
            ctx.backend->SetIpadView(esp.ipadView, esp.cameraFovDeg);
        }
        if (esp.ipadView) {
            if (LabeledSlider("##ipad_fov", "Camera FOV", &esp.cameraFovDeg, 80.0f, 130.0f, "%.0f deg") && ctx.backend) {
                ctx.backend->SetIpadView(true, esp.cameraFovDeg);
            }
        }
        EndCard();
        ImGui::EndTable();
    }
    ImGui::PopStyleVar(1);
}

void RenderAimTab() {
    auto& aim = IosUIBridge::GetContext().aim;
    float availW = ImGui::GetContentRegionAvail().x;
    int cols = (availW >= 480.0f) ? 2 : 1;

    ImGui::PushStyleVar(ImGuiStyleVar_CellPadding, ImVec2(5.0f, 4.0f));
    if (ImGui::BeginTable("##aim_grid", cols, ImGuiTableFlags_SizingStretchSame)) {
        ImGui::TableNextColumn();
        BeginCard("##aim_master", "AIM ASSIST", 3, false);
        ToggleSwitch("Master Aim", &aim.masterAim, nullptr, IM_COL32(175, 180, 195, 255));
        static const char* kTriggers[] = {"Trigger: Always", "Trigger: Scoped", "Trigger: Firing", "Trigger: Scoped & Firing"};
        LabeledCombo("Trigger Mode", "##aim_trigger", &aim.triggerMode, kTriggers, 4);
        EndCard();

        BeginCard("##aim_tuning", "AIM TUNING", 2, false);
        LabeledSlider("##aim_smooth", "Smoothness", &aim.smoothness, 1.0f, 20.0f, "%.1f");
        LabeledSlider("##fov_radius", "FOV", &aim.fovRadiusPx, 30.0f, 450.0f, "%.0f px");
        LabeledSlider("##aim_dist", "Aim Range", &aim.aimRangeMeters, 10.0f, 1000.0f, "%.0fm");
        aim.aimPower = std::clamp(aim.aimPower, 10.0f, 100.0f);
        LabeledSlider("##aim_power", "Aim Assist", &aim.aimPower, 10.0f, 100.0f, "%.0f%%");
        EndCard();

        ImGui::TableNextColumn();
        BeginCard("##aim_targeting", "TARGETING", 3, false);
        ToggleSwitch("Visible Check", &aim.visibleCheck, nullptr, IM_COL32(175, 180, 195, 255));
        ToggleSwitch("Ignore Knocked", &aim.ignoreKnocked, nullptr, IM_COL32(175, 180, 195, 255));
        ToggleSwitch("Target Bots", &aim.targetBots, nullptr, IM_COL32(175, 180, 195, 255));
        ToggleSwitch("FOV Circle", &aim.showFovCircle, nullptr, IM_COL32(175, 180, 195, 255));
        static const char* kBones[] = {"Bone: Head", "Bone: Chest", "Bone: Pelvis"};
        LabeledCombo("Target Bone", "##aim_bone", &aim.targetBone, kBones, 3);
        EndCard();
        ImGui::EndTable();
    }
    ImGui::PopStyleVar(1);
}

void RenderMemoryTab() {
    auto& ctx = IosUIBridge::GetContext();
    auto* be = ctx.backend;
    float availW = ImGui::GetContentRegionAvail().x;
    int cols = (availW >= 480.0f) ? 2 : 1;

    ImGui::PushStyleVar(ImGuiStyleVar_CellPadding, ImVec2(5.0f, 4.0f));
    if (ImGui::BeginTable("##memory_grid", cols, ImGuiTableFlags_SizingStretchSame)) {
        ImGui::TableNextColumn();
        BeginCard("##movement", "MOVEMENT", 0, false);
        RenderFeatureRow(IosUIBridge::MemoryFeature::NoFallDamage, "No Fall");
        EndCard();

        BeginCard("##fast", "FAST MODE", 5, false);
        // SpeedHack: custom toggle that passes slider value as param
        {
            auto* be = ctx.backend;
            IosUIBridge::FeatureStatus spSt = be
                ? be->GetMemoryFeatureStatus(IosUIBridge::MemoryFeature::SpeedHack)
                : IosUIBridge::FeatureStatus{};
            const char* spBadge = spSt.pending ? "Applying..."
                                : spSt.error   ? "Error"
                                : spSt.enabled ? "Active"
                                               : "Inactive";
            ImU32 spBadgeCol = spSt.pending ? IM_COL32(255,198,107,255)
                             : spSt.error   ? IM_COL32(255, 80, 90,255)
                             : spSt.enabled ? IM_COL32( 70,221,225,255)
                                           : IM_COL32(175,180,195,255);
            bool spVal = spSt.enabled;
            ImGui::BeginDisabled(spSt.pending);
            if (ToggleSwitch("Fast Move", &spVal, spBadge, spBadgeCol) && be) {
                be->RequestMemoryFeature(
                    IosUIBridge::MemoryFeature::SpeedHack, spVal,
                    ctx.layout.speedMultiplier);
                PushToast(spVal ? "Fast Move requested" : "Fast Move off");
            }
            ImGui::EndDisabled();
        }
        if (LabeledSlider("##speed_slider", "Speed Multiplier", &ctx.layout.speedMultiplier, 1.1f, 50.0f, "%.1fx") && be) {
            be->SetSpeedMultiplier(ctx.layout.speedMultiplier);
        }
        RenderFeatureRow(IosUIBridge::MemoryFeature::FastParachute);
        if (ImGui::Button("Jump", ImVec2(std::max(ImGui::GetContentRegionAvail().x - 4.0f, 1.0f), 30.0f)) && be) {
            be->ExecuteTeleportAction("parachute_jump", "player", -1);
        }
        EndCard();

        ImGui::TableNextColumn();
        BeginCard("##unlimited", "UNLIMITED", 1, false);
        static bool unlimAmmo = false;
        RenderFeatureToggle("Unlimited Ammo", &unlimAmmo, IosUIBridge::MemoryFeature::UnlimitedAmmo);
        if (IosUIBridge::GetContext().backend) {
            auto st = IosUIBridge::GetContext().backend->GetMemoryFeatureStatus(
                IosUIBridge::MemoryFeature::UnlimitedAmmo);
            if (st.enabled && !st.detail.empty()) {
                ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.45f, 0.90f, 0.72f, 0.75f));
                ImGui::TextUnformatted(st.detail.c_str());
                ImGui::PopStyleColor(1);
            }
        }
        EndCard();

        ImGui::EndTable();
    }
    ImGui::PopStyleVar(1);
}

void RenderSettingsTab() {
    auto& ctx = IosUIBridge::GetContext();
    auto* be = ctx.backend;
    float availW = ImGui::GetContentRegionAvail().x;
    int cols = (availW >= 480.0f) ? 2 : 1;

    ImGui::PushStyleVar(ImGuiStyleVar_CellPadding, ImVec2(5.0f, 4.0f));
    if (ImGui::BeginTable("##settings_grid", cols, ImGuiTableFlags_SizingStretchSame)) {
        ImGui::TableNextColumn();
        BeginCard("##settings_display", "DISPLAY", 2, true);
        float bw = std::max(ImGui::GetContentRegionAvail().x - 4.0f, 1.0f);
        if (ImGui::Button("Start ESP / Aim Engine", ImVec2(bw, 32.0f))) {
            ctx.layout.engineStarted = !ctx.layout.engineStarted;
            if (be) be->SetEngineEnabled(ctx.layout.engineStarted);
        }

        ImVec2 lp1 = ImGui::GetCursorScreenPos();
        ImGui::GetWindowDrawList()->AddLine(lp1, ImVec2(lp1.x + bw, lp1.y), IM_COL32(60, 68, 83, 180), 1.0f);
        ImGui::Dummy(ImVec2(bw, 1.0f));

        if (ImGui::Button("Reset menu layout", ImVec2(bw, 32.0f))) {
            ctx.layout.menuPosX = -1.0f;
            ctx.layout.menuPosY = -1.0f;
            ctx.layout.menuWidth = -1.0f;
            ctx.layout.menuHeight = -1.0f;
            ctx.layout.uiScale = 1.0f;
        }

        ToggleSwitch("Crosshair", &ctx.layout.crosshair, nullptr, IM_COL32(175, 180, 195, 255));
        ToggleSwitch("Watermark", &ctx.layout.watermark, nullptr, IM_COL32(175, 180, 195, 255));
        ToggleSwitch("Hide Recording", &ctx.layout.hideRecording, nullptr, IM_COL32(175, 180, 195, 255));
        LabeledSlider("##menu_scale", "Text size", &ctx.layout.uiScale, 0.70f, 1.20f, "%.2fx");

        ImVec2 lp2 = ImGui::GetCursorScreenPos();
        ImGui::GetWindowDrawList()->AddLine(lp2, ImVec2(lp2.x + bw, lp2.y), IM_COL32(60, 68, 83, 180), 1.0f);
        ImGui::Dummy(ImVec2(bw, 1.0f));

        ToggleSwitch("Feature Icons", &ctx.layout.showFeatureIcons, nullptr, IM_COL32(175, 180, 195, 255));

        if (ImGui::Button("Reset floating positions", ImVec2(std::max(ImGui::GetContentRegionAvail().x - 4.0f, 1.0f), 30.0f))) {
            ctx.layout.islandPosX = -1.0f;
            ctx.layout.islandPosY = -1.0f;
            for (int i = 0; i < 4; ++i) {
                ctx.layout.featurePos[i][0] = -1.0f;
                ctx.layout.featurePos[i][1] = -1.0f;
            }
        }
        EndCard();

        ImGui::TableNextColumn();
        BeginCard("##settings_actions", "ACTIONS", 1, true);
        ImGui::TextColored(ImVec4(0.45f, 0.90f, 0.88f, 1.00f), "Status: Standalone Overlay Active");
        ImGui::Spacing();
        float bw2 = std::max(ImGui::GetContentRegionAvail().x - 4.0f, 1.0f);
        if (ImGui::Button("Save Settings Now", ImVec2(bw2, 32.0f))) {
            SaveSettings();
            PushToast("Settings saved successfully");
        }
        ImGui::Spacing();

        if (ImGui::Button("Hide Menu", ImVec2(bw2, 30.0f))) {
            ctx.layout.menuOpen = false;
        }
        ImGui::Spacing();
        if (ImGui::Button("Reset Settings", ImVec2(bw2, 30.0f))) {
            ctx.esp = IosUIBridge::EspSettings{};
            ctx.aim = IosUIBridge::AimSettings{};
            if (be) be->ResetAllSettings();
            PushToast("Settings reset");
        }
        EndCard();

        ImGui::EndTable();
    }
    ImGui::PopStyleVar(1);
}

void RenderMainMenu() {
    auto& ctx = IosUIBridge::GetContext();
    auto& layout = ctx.layout;

    ImGuiStyle savedStyle = ImGui::GetStyle();
    ApplyTheme();

    ImGuiIO& io = ImGui::GetIO();
    float screenW = io.DisplaySize.x;
    float screenH = io.DisplaySize.y;
    float scale = std::clamp(layout.uiScale, 0.70f, 1.20f);

    float targetW = (screenW < screenH) ? 520.0f : (screenH >= 600.0f ? 420.0f : 340.0f);
    targetW = std::clamp(targetW, 1.0f, std::min(std::max(screenW - 12.0f, 1.0f), 260.0f * 2.0f));
    float targetH = std::clamp(screenH * 0.80f, 1.0f, std::max(screenH - 12.0f, 1.0f));

    if (layout.menuWidth <= 0.0f) layout.menuWidth = std::max(targetW, 420.0f);
    if (layout.menuHeight <= 0.0f) layout.menuHeight = targetH;
    layout.menuWidth = std::clamp(layout.menuWidth, 260.0f, std::max(260.0f, screenW - 12.0f));
    layout.menuHeight = std::clamp(layout.menuHeight, 180.0f, std::max(180.0f, screenH - 12.0f));

    if (layout.menuPosX < 0.0f || layout.menuPosY < 0.0f) {
        layout.menuPosX = (screenW - layout.menuWidth) * 0.5f;
        layout.menuPosY = (screenH - layout.menuHeight) * 0.5f;
    }
    layout.menuPosX = std::clamp(layout.menuPosX, 6.0f, std::max(6.0f, screenW - layout.menuWidth - 6.0f));
    layout.menuPosY = std::clamp(layout.menuPosY, 6.0f, std::max(6.0f, screenH - layout.menuHeight - 6.0f));

    ImGui::SetNextWindowPos(ImVec2(layout.menuPosX, layout.menuPosY), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(layout.menuWidth, layout.menuHeight), ImGuiCond_Always);

    ImGuiWindowFlags winFlags = ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                                ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoSavedSettings |
                                ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse |
                                ImGuiWindowFlags_NoBringToFrontOnFocus | ImGuiWindowFlags_NoNavFocus;

    layout.menuBackdropActive = true;
    if (ImGui::Begin("##AnhAhKaNgHahMainWindow", nullptr, winFlags)) {
        ImGui::SetWindowFontScale(scale);
        ImVec2 wp = ImGui::GetWindowPos();
        ImVec2 ws = ImGui::GetWindowSize();
        layout.menuPosX = wp.x;
        layout.menuPosY = wp.y;
        layout.menuWidth = ws.x;
        layout.menuHeight = ws.y;
        layout.menuBackdropX = wp.x;
        layout.menuBackdropY = wp.y;
        layout.menuBackdropW = ws.x;
        layout.menuBackdropH = ws.y;

        ImDrawList* dl = ImGui::GetWindowDrawList();
        dl->AddRect(wp, ImVec2(wp.x + ws.x, wp.y + ws.y), IM_COL32(235, 245, 255, 22), 17.0f, 0, 1.0f);
        dl->AddLine(ImVec2(wp.x + 18.0f, wp.y + 1.0f), ImVec2(wp.x + ws.x - 18.0f, wp.y + 1.0f), 0x37FFFFFF, 1.0f);

        // Header strip
        ImVec2 headerPos = ImGui::GetCursorScreenPos();
        float availW = ImGui::GetContentRegionAvail().x;
        ImGui::Dummy(ImVec2(availW, 36.0f));

        ImVec2 chipMin(headerPos.x + 2.0f, headerPos.y + 4.0f);
        ImVec2 chipMax(chipMin.x + 28.0f, chipMin.y + 28.0f);
        dl->AddRectFilled(chipMin, chipMax, IM_COL32(70, 221, 225, 35), 8.0f);
        DrawVectorIcon(dl, 13, ImVec2(chipMin.x + 14.0f, chipMin.y + 14.0f), IM_COL32(239, 205, 128, 255), 20.0f);

        ImFont* titleFont = gHeaderTitleFont ? gHeaderTitleFont : ImGui::GetFont();
        const char* titleTxt = "AnhAhKaNgHah";
        ImVec2 titlePos(chipMax.x + 8.0f, headerPos.y + 5.0f);
        dl->AddText(titleFont, 14.5f, titlePos, IM_COL32(243, 242, 247, 255), titleTxt);
        dl->AddText(ImGui::GetFont(), 9.0f, ImVec2(titlePos.x, titlePos.y + 16.0f), IM_COL32(181, 165, 201, 255), "OVERLAY ACTIVE");

        // "VIP" pill badge right of title
        ImVec2 titleSz = titleFont->CalcTextSizeA(14.5f, FLT_MAX, 0.0f, titleTxt);
        ImVec2 vipMin(titlePos.x + titleSz.x + 8.0f, titlePos.y + 1.0f);
        ImVec2 vipMax(vipMin.x + 30.0f, vipMin.y + 16.0f);
        if (vipMax.x < wp.x + ws.x - 48.0f) {
            dl->AddRectFilled(vipMin, vipMax, IM_COL32(21, 58, 66, 255), 6.0f);
            dl->AddText(ImGui::GetFont(), 10.5f, ImVec2(vipMin.x + 6.0f, vipMin.y + 2.0f), IM_COL32(135, 237, 225, 255), "VIP");
        }

        // Top-right close circle button
        ImGui::SetCursorScreenPos(ImVec2(headerPos.x + availW - 36.0f, headerPos.y));
        if (ImGui::InvisibleButton("##CloseBtn", ImVec2(36.0f, 36.0f))) {
            layout.menuOpen = false;
        }
        bool closeHov = ImGui::IsItemHovered();
        ImVec2 closeCenter(headerPos.x + availW - 18.0f, headerPos.y + 18.0f);
        dl->AddCircleFilled(closeCenter, 14.0f, closeHov ? IM_COL32(220, 230, 245, 48) : IM_COL32(220, 230, 245, 22), 24);
        dl->AddLine(ImVec2(closeCenter.x - 4.5f, closeCenter.y - 4.5f), ImVec2(closeCenter.x + 4.5f, closeCenter.y + 4.5f), IM_COL32(188, 196, 210, 255), 1.4f);
        dl->AddLine(ImVec2(closeCenter.x + 4.5f, closeCenter.y - 4.5f), ImVec2(closeCenter.x - 4.5f, closeCenter.y + 4.5f), IM_COL32(188, 196, 210, 255), 1.4f);

        // Drag header region
        ImVec2 mPos = io.MousePos;
        bool inHeader = (mPos.x >= wp.x + 4.0f && mPos.x <= wp.x + ws.x - 44.0f &&
                         mPos.y >= wp.y + 4.0f && mPos.y <= wp.y + 46.0f);
        ImVec2 winPosTmp = wp;
        HandleWindowDrag(ws, inHeader, true, &winPosTmp, screenW, screenH, true);
        layout.menuPosX = winPosTmp.x;
        layout.menuPosY = winPosTmp.y;

        // 4-tab bar (Teleport and Hand tabs hidden)
        ImGui::SetCursorScreenPos(ImVec2(headerPos.x, headerPos.y + 44.0f));
        ImVec2 tabBarPos = ImGui::GetCursorScreenPos();
        float tabW = std::max(availW, 60.0f);
        dl->AddRectFilled(tabBarPos, ImVec2(tabBarPos.x + tabW, tabBarPos.y + 32.0f), IM_COL32(10, 14, 22, 58), 9.0f);

        bool compactTabs = (tabW < 340.0f);
        static const char* kFullTabs[4] = {"ESP", "Aim", "Memory", "Settings"};
        static const char* kCompactTabs[4] = {"ESP", "Aim", "Mem", "Set"};
        float btnW = tabW / 4.0f;
        layout.activeTab = std::clamp(layout.activeTab, 0, 3);

        ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(4.0f, 6.0f));
        for (int i = 0; i < 4; ++i) {
            if (i > 0) ImGui::SameLine(0.0f, 0.0f);
            bool sel = (layout.activeTab == i);
            ImGui::PushStyleColor(ImGuiCol_Button, sel ? ImVec4(0.16f, 0.69f, 0.72f, 0.32f) : ImVec4(0, 0, 0, 0));
            ImGui::PushStyleColor(ImGuiCol_Text, sel ? ImVec4(0.99f, 1.00f, 1.00f, 1.00f) : ImVec4(0.65f, 0.72f, 0.82f, 1.00f));
            if (ImGui::Button(compactTabs ? kCompactTabs[i] : kFullTabs[i], ImVec2(btnW, 32.0f))) {
                layout.activeTab = i;
            }
            ImGui::PopStyleColor(2);
        }
        ImGui::PopStyleVar(1);

        ImGui::Dummy(ImVec2(0.0f, 2.0f));

        // Scrollable tab content container
        static float sTabScrollY = 0.0f;
        static bool sTabScrolling = false;
        ImVec2 rem = ImGui::GetContentRegionAvail();
        ImGui::PushID(layout.activeTab);
        if (ImGui::BeginChild("##TabScrollContent", ImVec2(rem.x, std::max(rem.y - 24.0f, 40.0f)), false, ImGuiWindowFlags_AlwaysVerticalScrollbar)) {
            HandleFingerScroll(&sTabScrollY, &sTabScrolling, true);
            switch (layout.activeTab) {
                case 0: RenderEspTab(); break;
                case 1: RenderAimTab(); break;
                case 2: RenderMemoryTab(); break;
                case 3: RenderSettingsTab(); break;
            }
        }
        ImGui::EndChild();
        ImGui::PopID();

        // Bottom separator + 3-line resize grip
        ImVec2 bot = ImGui::GetCursorScreenPos();
        dl->AddLine(ImVec2(bot.x, bot.y + 4.0f), ImVec2(bot.x + availW, bot.y + 4.0f), IM_COL32(48, 55, 67, 180), 1.0f);
        ImVec2 br(wp.x + ws.x - 6.0f, wp.y + ws.y - 6.0f);
        ImU32 gripCol = IM_COL32(112, 123, 143, 255);
        dl->AddLine(ImVec2(br.x - 4.0f, br.y), ImVec2(br.x, br.y - 4.0f), gripCol, 1.5f);
        dl->AddLine(ImVec2(br.x - 8.0f, br.y), ImVec2(br.x, br.y - 8.0f), gripCol, 1.5f);
        dl->AddLine(ImVec2(br.x - 12.0f, br.y), ImVec2(br.x, br.y - 12.0f), gripCol, 1.5f);
    }
    ImGui::End();

    ImGui::GetStyle() = savedStyle;
}

void RenderDynamicIsland(ImDrawList* draw, ImVec2 displaySize, int players, int bots) {
    if (!draw) return;
    auto& ctx = IosUIBridge::GetContext();
    auto& layout = ctx.layout;

    double now = ImGui::GetTime();
    bool hasToast = !ctx.toastText.empty() && ((now - ctx.toastStartTime) < 1.15);

    char pBuf[16], bBuf[16];
    std::snprintf(pBuf, sizeof(pBuf), "%d", players);
    std::snprintf(bBuf, sizeof(bBuf), "%d", bots);

    ImFont* font = ImGui::GetFont();
    ImVec2 pSz = font->CalcTextSizeA(13.5f, FLT_MAX, 0.0f, pBuf);
    ImVec2 bSz = font->CalcTextSizeA(13.5f, FLT_MAX, 0.0f, bBuf);
    ImVec2 toastSz = hasToast ? font->CalcTextSizeA(11.0f, FLT_MAX, 0.0f, ctx.toastText.c_str()) : ImVec2(0, 0);

    float pillW = hasToast ? std::max(146.0f, toastSz.x + 28.0f) : std::max(114.0f, 52.0f + pSz.x + bSz.x);
    float pillH = 30.0f;
    ImVec2 origin = GetIslandPos(pillW, pillH, displaySize.x, displaySize.y);
    ImVec2 endPt(origin.x + pillW, origin.y + pillH);

    layout.hubBackdropActive = true;
    layout.hubBackdropX = origin.x;
    layout.hubBackdropY = origin.y;
    layout.hubBackdropW = pillW;
    layout.hubBackdropH = pillH;

    float pulse = std::sin(static_cast<float>(now) * 2.0f) * 0.5f + 0.5f;
    ImU32 glowA = static_cast<ImU32>(22.0f + pulse * 18.0f);
    draw->AddRect(
        ImVec2(origin.x - 1.0f, origin.y - 1.0f),
        ImVec2(endPt.x + 1.0f, endPt.y + 1.0f),
        IM_COL32(70, 221, 225, glowA), pillH * 0.5f, 0, 1.0f);
    draw->AddRectFilled(ImVec2(origin.x, origin.y + 2.0f), ImVec2(endPt.x, endPt.y + 2.0f), 0x55000000, pillH * 0.5f);
    draw->AddRectFilled(origin, endPt, IM_COL32(14, 23, 34, 245), pillH * 0.5f);
    draw->AddRect(origin, endPt, IM_COL32(87, 139, 158, 110), pillH * 0.5f, 0, 1.0f);

    if (hasToast) {
        draw->PushClipRect(ImVec2(origin.x + 8.0f, origin.y), ImVec2(endPt.x - 8.0f, endPt.y), true);
        draw->AddText(font, 11.0f,
                      ImVec2(origin.x + (pillW - toastSz.x) * 0.5f, origin.y + (pillH - toastSz.y) * 0.5f),
                      IM_COL32(245, 245, 250, 255),
                      ctx.toastText.c_str());
        draw->PopClipRect();
    } else {
        float midX = origin.x + pillW * 0.5f;
        float midY = origin.y + pillH * 0.5f;
        draw->AddLine(ImVec2(midX, midY - 6.0f), ImVec2(midX, midY + 6.0f), IM_COL32(80, 83, 95, 210), 1.0f);

        DrawVectorIcon(draw, 0, ImVec2(origin.x + 18.0f, midY), IM_COL32(255, 139, 158, 255), 14.0f);
        draw->AddText(font, 13.5f, ImVec2(origin.x + 29.0f, midY - pSz.y * 0.5f), IM_COL32(255, 139, 158, 255), pBuf);

        DrawVectorIcon(draw, 1, ImVec2(midX + 14.0f, midY), IM_COL32(135, 237, 190, 255), 14.0f);
        draw->AddText(font, 13.5f, ImVec2(midX + 25.0f, midY - bSz.y * 0.5f), IM_COL32(135, 237, 190, 255), bBuf);
    }
}

void RenderEdgeArrow(ImDrawList* draw, ImVec2 displaySize, float angleRad, bool isBot, float distMeters) {
    if (!draw) return;
    float cx = displaySize.x * 0.5f;
    float cy = displaySize.y * 0.5f;
    float cs = std::cosf(angleRad);
    float sn = std::sinf(angleRad);

    char dBuf[24];
    std::snprintf(dBuf, sizeof(dBuf), "%.0fm", distMeters);
    ImFont* font = ImGui::GetFont();
    ImVec2 txtSz = font->CalcTextSizeA(11.0f, FLT_MAX, 0.0f, dBuf);

    float pillW = txtSz.x + 10.0f;
    float pillH = txtSz.y + 6.0f;
    float halfW = pillW * 0.5f + 4.0f;
    float halfH = pillH * 0.5f + 4.0f;

    float minX = halfW + 6.0f;
    float maxX = displaySize.x - halfW - 6.0f;
    float minY = halfH + 6.0f;
    float maxY = displaySize.y - halfH - 6.0f;

    // Ray-box intersection to clamp badge directly against screen borders
    float t = 10000.0f;
    if (std::abs(cs) > 1e-4f) {
        float tx = (cs > 0.0f) ? (maxX - cx) / cs : (minX - cx) / cs;
        if (tx > 0.0f) t = std::min(t, tx);
    }
    if (std::abs(sn) > 1e-4f) {
        float ty = (sn > 0.0f) ? (maxY - cy) / sn : (minY - cy) / sn;
        if (ty > 0.0f) t = std::min(t, ty);
    }

    ImVec2 center(cx + cs * t, cy + sn * t);
    center.x = std::clamp(center.x, minX, maxX);
    center.y = std::clamp(center.y, minY, maxY);

    ImU32 fillCol = isBot ? IM_COL32(34, 197, 94, 245) : IM_COL32(235, 45, 45, 245);

    // Direction pointer triangle pointing off-screen
    ImVec2 tip(center.x + cs * 12.0f, center.y + sn * 12.0f);
    ImVec2 p1(center.x - sn * 5.0f, center.y + cs * 5.0f);
    ImVec2 p2(center.x + sn * 5.0f, center.y - cs * 5.0f);
    draw->AddTriangleFilled(tip, p1, p2, fillCol);

    // Rounded speech-bubble pill body
    ImVec2 bMin(center.x - pillW * 0.5f, center.y - pillH * 0.5f);
    ImVec2 bMax(center.x + pillW * 0.5f, center.y + pillH * 0.5f);
    draw->AddRectFilled(bMin, bMax, fillCol, 4.0f);

    // Crisp pure white text
    draw->AddText(font, 11.0f, ImVec2(bMin.x + 5.0f, bMin.y + 3.0f), IM_COL32(255, 255, 255, 255), dBuf);
}

void RenderEspOverlay(ImDrawList* draw, ImVec2 displaySize) {
    if (!draw) return;
    auto& ctx = IosUIBridge::GetContext();
    const auto& esp = ctx.esp;
    const auto& aim = ctx.aim;

    if (esp.masterEsp && ctx.backend) {
        static const int kBonePairs[][2] = {
            {0, 1}, {1, 2}, {2, 3}, {1, 4}, {4, 5}, {5, 6},
            {1, 7}, {7, 8}, {8, 9}, {3, 10}, {10, 11}, {11, 12},
            {3, 13}, {13, 14}, {14, 15}
        };

        struct EspLabel {
            const IosUIBridge::OverlayEntity* entity;
            ImU32 accent;
        };
        std::vector<EspLabel> labels;

        const auto& ents = ctx.backend->GetEntities();
        for (const auto& e : ents) {
            if (e.distanceMeters > esp.espRangeMeters) continue;
            if (esp.hideBots && e.isBot) continue;

            ImU32 col = e.isBot ? IM_COL32(75, 200, 174, 190) : IM_COL32(242, 112, 122, 195);
            if (!e.onScreen) {
                if (esp.edgeArrows) {
                    RenderEdgeArrow(draw, displaySize, e.offscreenAngleRad, e.isBot, e.distanceMeters);
                }
                continue;
            }

            // Keep snaplines quiet so dense groups do not dominate the screen.
            if (esp.snaplines) {
                ImVec2 origin(displaySize.x * 0.5f, 26.0f);
                if (esp.snaplineOrigin == 0) origin = ImVec2(displaySize.x * 0.5f, 0.0f);
                else if (esp.snaplineOrigin == 1) origin = ImVec2(displaySize.x * 0.5f, displaySize.y * 0.5f);
                else if (esp.snaplineOrigin == 2) origin = ImVec2(displaySize.x * 0.5f, displaySize.y);
                else if (esp.snaplineOrigin == 3) origin = ImVec2(displaySize.x * 0.5f, 26.0f);
                ImU32 lineCol = e.isBot ? IM_COL32(75, 200, 174, 65) : IM_COL32(242, 112, 122, 72);
                draw->AddLine(origin, ImVec2((e.minX + e.maxX) * 0.5f, e.minY), lineCol, 0.8f);
            }

            // Lightweight boxes leave the game scene visible.
            if (esp.boxes) {
                if (esp.boxStyle == 1) { // Corner brackets
                    float w = e.maxX - e.minX;
                    float h = e.maxY - e.minY;
                    float cw = std::max(w * 0.25f, 4.0f);
                    float ch = std::max(h * 0.20f, 4.0f);
                    auto corner = [&](ImVec2 a, ImVec2 b, ImVec2 c) {
                        draw->AddLine(a, b, col, 1.2f);
                        draw->AddLine(a, c, col, 1.2f);
                    };
                    corner(ImVec2(e.minX, e.minY), ImVec2(e.minX + cw, e.minY), ImVec2(e.minX, e.minY + ch));
                    corner(ImVec2(e.maxX, e.minY), ImVec2(e.maxX - cw, e.minY), ImVec2(e.maxX, e.minY + ch));
                    corner(ImVec2(e.minX, e.maxY), ImVec2(e.minX + cw, e.maxY), ImVec2(e.minX, e.maxY - ch));
                    corner(ImVec2(e.maxX, e.maxY), ImVec2(e.maxX - cw, e.maxY), ImVec2(e.maxX, e.maxY - ch));
                } else if (esp.boxStyle == 2) { // 3D box
                    float w = e.maxX - e.minX;
                    float h = e.maxY - e.minY;
                    float dx = w * 0.22f;
                    float dy = -h * 0.12f;
                    ImVec2 f0(e.minX, e.minY), f1(e.maxX, e.minY), f2(e.maxX, e.maxY), f3(e.minX, e.maxY);
                    ImVec2 b0(f0.x + dx, f0.y + dy), b1(f1.x + dx, f1.y + dy), b2(f2.x + dx, f2.y + dy), b3(f3.x + dx, f3.y + dy);
                    draw->AddLine(f0, b0, col, 1.5f); draw->AddLine(f1, b1, col, 1.5f);
                    draw->AddLine(f2, b2, col, 1.5f); draw->AddLine(f3, b3, col, 1.5f);
                    draw->AddLine(b0, b1, col, 1.5f); draw->AddLine(b1, b2, col, 1.5f);
                    draw->AddLine(b2, b3, col, 1.5f); draw->AddLine(b3, b0, col, 1.5f);
                    draw->AddLine(f0, f1, col, 1.5f); draw->AddLine(f1, f2, col, 1.5f);
                    draw->AddLine(f2, f3, col, 1.5f); draw->AddLine(f3, f0, col, 1.5f);
                } else { // Standard 2D Box
                    draw->AddRect(ImVec2(e.minX, e.minY), ImVec2(e.maxX, e.maxY), col, 0.0f, 0, 1.0f);
                }
            }

            // Skeleton - Pure white lines and head circle
            if (esp.skeleton) {
                for (const auto& pair : kBonePairs) {
                    if (e.boneValid[pair[0]] && e.boneValid[pair[1]]) {
                        draw->AddLine(
                            ImVec2(e.bonePos[pair[0]][0], e.bonePos[pair[0]][1]),
                            ImVec2(e.bonePos[pair[1]][0], e.bonePos[pair[1]][1]),
                            IM_COL32(226, 236, 242, 170), 1.1f);
                    }
                }
                if (e.boneValid[0]) {
                    float hr = std::clamp((e.maxY - e.minY) * 0.08f, 3.0f, 9.0f);
                    draw->AddCircle(ImVec2(e.bonePos[0][0], e.bonePos[0][1]), hr, IM_COL32(226, 236, 242, 170), 16, 1.1f);
                }
            }

            // Health bar
            if (esp.health && e.maxHealth > 0.0f) {
                float frac = std::clamp(e.health / e.maxHealth, 0.0f, 1.0f);
                float h = e.maxY - e.minY;
                ImVec2 hbMin(e.minX - 5.0f, e.minY);
                ImVec2 hbMax(e.minX - 2.0f, e.maxY);
                draw->AddRectFilled(hbMin, hbMax, IM_COL32(10, 12, 16, 180));
                ImU32 hCol = frac > 0.5f ? IM_COL32(34, 197, 94, 255) : IM_COL32(255, 195, 45, 255);
                draw->AddRectFilled(ImVec2(hbMin.x, e.maxY - h * frac), hbMax, hCol);
            }

            if ((esp.name && !e.name.empty()) || esp.distance) labels.push_back({&e, col});
        }

        // Place closer players first; move crowded labels upward or omit them.
        std::sort(labels.begin(), labels.end(), [](const EspLabel& a, const EspLabel& b) {
            return a.entity->distanceMeters < b.entity->distanceMeters;
        });
        std::vector<ImVec4> occupied;
        ImFont* font = ImGui::GetFont();
        for (const EspLabel& item : labels) {
            const auto& e = *item.entity;
            const float nameSize = 9.5f;
            const float distanceSize = 9.0f;
            char distanceText[24] = {};
            if (esp.distance) std::snprintf(distanceText, sizeof(distanceText), "%.0fm", e.distanceMeters);
            const bool showName = esp.name && !e.name.empty();
            const float nameWidth = showName ? std::min(font->CalcTextSizeA(nameSize, FLT_MAX, 0.0f, e.name.c_str()).x, 112.0f) : 0.0f;
            const float distanceWidth = esp.distance ? font->CalcTextSizeA(distanceSize, FLT_MAX, 0.0f, distanceText).x : 0.0f;
            const float width = 12.0f + nameWidth + (showName && esp.distance ? 8.0f : 0.0f) + distanceWidth + (esp.distance ? 5.0f : 0.0f);
            const float height = 16.0f;
            const float x = std::clamp((e.minX + e.maxX - width) * 0.5f, 3.0f, std::max(3.0f, displaySize.x - width - 3.0f));
            float y = e.minY - height - 3.0f;
            bool placed = false;
            for (int row = 0; row < 4 && y >= 3.0f; ++row, y -= height + 3.0f) {
                bool overlaps = false;
                for (const ImVec4& used : occupied) {
                    if (x < used.z + 3.0f && x + width + 3.0f > used.x && y < used.w + 3.0f && y + height + 3.0f > used.y) {
                        overlaps = true;
                        break;
                    }
                }
                if (!overlaps) { placed = true; break; }
            }
            if (!placed) continue;
            occupied.emplace_back(x, y, x + width, y + height);
            const ImVec2 min(x, y), max(x + width, y + height);
            draw->AddRectFilled(min, max, IM_COL32(15, 23, 34, 205), 5.0f);
            draw->AddRect(min, max, IM_COL32(176, 198, 210, 65), 5.0f, 0, 0.8f);
            draw->AddRectFilled(ImVec2(x + 3.0f, y + 3.0f), ImVec2(x + 5.0f, y + height - 3.0f), item.accent, 1.0f);
            float textX = x + 9.0f;
            if (showName) {
                draw->PushClipRect(ImVec2(textX, y), ImVec2(textX + nameWidth, y + height), true);
                draw->AddText(font, nameSize, ImVec2(textX, y + 2.0f), IM_COL32(242, 246, 249, 245), e.name.c_str());
                draw->PopClipRect();
                textX += nameWidth + 8.0f;
            }
            if (esp.distance) {
                draw->AddText(font, distanceSize, ImVec2(textX, y + 2.5f), IM_COL32(166, 188, 203, 240), distanceText);
            }
        }
    }

    if (ctx.layout.crosshair) {
        ImVec2 c(displaySize.x * 0.5f, displaySize.y * 0.5f);
        ImU32 crossCol = IM_COL32(255, 45, 65, 230);
        draw->AddLine(ImVec2(c.x - 7.0f, c.y), ImVec2(c.x + 7.0f, c.y), crossCol, 1.5f);
        draw->AddLine(ImVec2(c.x, c.y - 7.0f), ImVec2(c.x, c.y + 7.0f), crossCol, 1.5f);
    }

    if (aim.masterAim && aim.showFovCircle) {
        Aimbot::DrawFovCircle(draw, ImVec2(displaySize.x * 0.5f, displaySize.y * 0.5f));
    }
}

void RenderFloatingHUD() {
    auto& ctx = IosUIBridge::GetContext();
    auto& layout = ctx.layout;
    ImGuiIO& io = ImGui::GetIO();
    ImDrawList* fg = ImGui::GetForegroundDrawList();
    float w = io.DisplaySize.x;
    float h = io.DisplaySize.y;

    // Quick Feature Icon pills (Fast Move & No Fall only; Wallhack & Fly hidden)
    if (layout.showFeatureIcons && !layout.menuOpen) {
        static const int kFeatIcons[2] = {9, 10};
        static const char* kFeatLabels[2] = {"Fast Move", "No Fall"};
        static const ImU32 kFeatColors[2] = {
            IM_COL32(70, 221, 225, 255),
            IM_COL32(135, 237, 190, 255),
        };
        ImFont* font = ImGui::GetFont();
        for (int i = 0; i < 2; ++i) {
            bool active = false;
            bool pending = false;
            if (ctx.backend) {
                if (i == 0) {
                    auto st = ctx.backend->GetMemoryFeatureStatus(IosUIBridge::MemoryFeature::SpeedHack);
                    active = st.enabled; pending = st.pending;
                } else {
                    auto st = ctx.backend->GetMemoryFeatureStatus(IosUIBridge::MemoryFeature::NoFallDamage);
                    active = st.enabled; pending = st.pending;
                }
            }
            ImVec2 pos = GetFeatureIconPos(i, w, h);
            ImVec2 maxPt(pos.x + 94.0f, pos.y + 30.0f);
            DrawBadgeBox(fg, pos, maxPt, active, kFeatColors[i]);
            DrawVectorIcon(fg, kFeatIcons[i], ImVec2(pos.x + 15.0f, pos.y + 15.0f), kFeatColors[i], 16.0f);
            fg->AddText(font, 10.5f, ImVec2(pos.x + 28.0f, pos.y + 10.0f), IM_COL32(228, 240, 248, 255), kFeatLabels[i]);
            ImU32 dotCol = pending ? IM_COL32(255, 198, 107, 255) : (active ? kFeatColors[i] : IM_COL32(91, 109, 129, 180));
            fg->AddCircleFilled(ImVec2(maxPt.x - 8.0f, pos.y + 8.0f), 2.5f, dotCol, 16);
        }
    }
}

void RenderFrame() {
    auto& ctx = IosUIBridge::GetContext();
    auto& layout = ctx.layout;
    ImGuiIO& io = ImGui::GetIO();

    static bool gSettingsLoaded = false;
    if (!gSettingsLoaded) {
        gSettingsLoaded = true;
        LoadSettings();
    }

    static bool sPrevMenuOpen = false;
    if (sPrevMenuOpen && !layout.menuOpen) {
        SaveSettings();
    }
    sPrevMenuOpen = layout.menuOpen;

    layout.menuBackdropActive = false;
    layout.hubBackdropActive = false;

    if (layout.menuOpen) {
        RenderMainMenu();
    }

    RenderEspOverlay(ImGui::GetBackgroundDrawList(), io.DisplaySize);

    int players = 0, bots = 0;
    if (ctx.backend) {
        for (const auto& e : ctx.backend->GetEntities()) {
            if (e.isBot) ++bots;
            else ++players;
        }
    }
    RenderDynamicIsland(ImGui::GetForegroundDrawList(), io.DisplaySize, players, bots);
    RenderFloatingHUD();
}

bool IsPointInMenuOrFloatingHUD(float x, float y, float viewW, float viewH) {
    const auto& ctx = IosUIBridge::GetContext();
    const auto& layout = ctx.layout;

    if (layout.menuOpen &&
        x >= layout.menuPosX && x <= layout.menuPosX + layout.menuWidth &&
        y >= layout.menuPosY && y <= layout.menuPosY + layout.menuHeight) {
        return true;
    }

    if (layout.showFeatureIcons && !layout.menuOpen) {
        for (int i = 0; i < 2; ++i) {
            if (RectContains(GetFeatureIconPos(i, viewW, viewH), 94.0f, 30.0f, x, y)) return true;
        }
    }

    return GetIslandTouchRect(viewW, viewH).Contains(ImVec2(x, y));
}

void OnTouchBegan(float x, float y, float viewW, float viewH) {
    auto& ctx = IosUIBridge::GetContext();
    auto& layout = ctx.layout;
    gDraggedHudKind = -1;
    gDragMoved = false;
    gDragTouchStart = ImVec2(x, y);

    if (layout.showFeatureIcons && !layout.menuOpen) {
        for (int i = 0; i < 2; ++i) {
            ImVec2 fp = GetFeatureIconPos(i, viewW, viewH);
            if (RectContains(fp, 94.0f, 30.0f, x, y)) { gDraggedHudKind = 10 + i; gDragOrigPos = fp; return; }
        }
    }

    const ImRect island = GetIslandTouchRect(viewW, viewH);
    if (island.Contains(ImVec2(x, y))) { gDraggedHudKind = 1; gDragOrigPos = island.Min; }
}

void OnTouchMoved(float x, float y, float viewW, float viewH) {
    if (gDraggedHudKind < 0) return;

    float dx = x - gDragTouchStart.x;
    float dy = y - gDragTouchStart.y;
    // Require 14pt travel before switching from tap to drag so finger taps always toggle pills
    if (!gDragMoved && (dx * dx + dy * dy) > 196.0f) {
        gDragMoved = true;
    }
    if (!gDragMoved) return;

    const float w = gDraggedHudKind == 1 ? GetIslandTouchRect(viewW, viewH).GetWidth() : 94.0f;
    const float h = 30.0f;

    auto& layout = IosUIBridge::GetContext().layout;
    float nx = std::clamp(gDragOrigPos.x + dx, 4.0f, std::max(4.0f, viewW - w - 4.0f));
    float ny = std::clamp(gDragOrigPos.y + dy, 4.0f, std::max(4.0f, viewH - h - 4.0f));

    if (gDraggedHudKind == 1) { layout.islandPosX = nx; layout.islandPosY = ny; }
    else if (gDraggedHudKind >= 10 && gDraggedHudKind <= 11) {
        int i = gDraggedHudKind - 10;
        layout.featurePos[i][0] = nx; layout.featurePos[i][1] = ny;
    }
}

void OnTouchEnded(float x, float y, float viewW, float viewH) {
    (void)x; (void)y; (void)viewW; (void)viewH;
    auto& ctx = IosUIBridge::GetContext();
    auto* be = ctx.backend;

    if (gDraggedHudKind >= 0 && !gDragMoved) {
        if (gDraggedHudKind == 1) {
            ctx.layout.menuOpen = !ctx.layout.menuOpen;
        } else if (gDraggedHudKind >= 10 && gDraggedHudKind <= 11 && be) {
            int idx = gDraggedHudKind - 10;
            if (idx == 0) {
                bool nxt = !be->GetMemoryFeatureStatus(IosUIBridge::MemoryFeature::SpeedHack).enabled;
                be->RequestMemoryFeature(IosUIBridge::MemoryFeature::SpeedHack, nxt, ctx.layout.speedMultiplier);
                PushToast(nxt ? "Fast Move ON" : "Fast Move OFF");
            } else {
                bool nxt = !be->GetMemoryFeatureStatus(IosUIBridge::MemoryFeature::NoFallDamage).enabled;
                be->RequestMemoryFeature(IosUIBridge::MemoryFeature::NoFallDamage, nxt, 1.0f);
                PushToast(nxt ? "No Fall ON" : "No Fall OFF");
            }
            SaveSettings();
        }
    } else if (gDragMoved) {
        SaveSettings();
    }
    gDraggedHudKind = -1;
    gDragMoved = false;
}

void OnTouchCancelled() {
    gDraggedHudKind = -1;
    gDragMoved = false;
}

} // namespace IosUI
