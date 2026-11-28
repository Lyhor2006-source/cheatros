#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct ImVec2;
struct ImVec4;

namespace IosUIBridge {

enum class EspStyle : int {
    CrownPulse = 0,
    VideoTrace = 1,
};

enum class SnaplineOrigin : int {
    Top = 0,
    Crosshair = 1,
    Bottom = 2,
    CountHub = 3,
};

enum class BoxStyle : int {
    Standard2D = 0,
    CornerBrackets = 1,
    Perspective3D = 2,
};

enum class AimTriggerMode : int {
    Always = 0,
    Scoped = 1,
    Firing = 2,
    ScopedAndFiring = 3,
};

enum class TargetBone : int {
    Head = 0,
    Chest = 1,
    Pelvis = 2,
};

enum class HandWeaponSlot : int {
    AWM = 0,
    RPG = 1,      // Skipped in Hand tab selector
    BARRETT = 2,
    BOW = 3,
    CROSSBOW = 4, // Skipped in Hand tab selector
};

enum class MemoryFeature : int {
    AkmOneHit       = 0x00,
    DesertEagleRpg  = 0x01,
    G18cRpg         = 0x02,
    M4a1OneHit      = 0x03,
    OneHitAllGun    = 0x04,
    NoRecoil        = 0x05,
    AutoScope       = 0x06,
    HighScope       = 0x07,
    FastShot        = 0x08,
    FastReload      = 0x09,
    FastHeal        = 0x0A,
    SpeedHack       = 0x0B,
    WallV2          = 0x0C,
    NoFallDamage    = 0x0D,
    NoGrass         = 0x0E,
    FastParachute   = 0x0F,
    IpadView        = 0x10,
    ClearFog        = 0x11,
    P90OneHit       = 0x12,
    QbzOneHit       = 0x13,
    Pp19OneHit      = 0x14,
    Mp5OneHit       = 0x15,
    VectorOneHit    = 0x16,
    RemovedFeature  = 0x17,
    AkmRpg          = 0x18,
    FastParachuteV2 = 0x19,
    GhostDesync     = 0x1A,
    GhostVisual     = 0x1B,
    ClearWater      = 0x1C,
    WallV1          = 0x1D,
    SuperJump       = 0x1E,
    SpiderClimb     = 0x1F,
    ZeroGravity     = 0x20,
    MagicBullet     = 0x21,
    WaterWalk       = 0x22,
    InfiniteBreath  = 0x23,
    AntiCheatShield = 0x24,
    AutoReload      = 0x25,
    UnlimitedAmmo   = 0x26,
    HealerAim       = 0x27,
    Count           = 0x28,
};

struct FeatureStatus {
    bool enabled = false;
    bool pending = false;
    bool error = false;
    bool active = false;
    std::string detail;
};

struct EspSettings {
    bool masterEsp = true;
    int style = 0;            // 0: CrownPulse, 1: VideoTrace
    int boxStyle = 0;         // 0: 2D Box, 1: Corner Box, 2: 3D Box
    bool boxes = true;
    bool skeleton = true;
    bool health = true;
    bool name = true;
    bool distance = true;
    bool edgeArrows = true;
    bool snaplines = false;
    int snaplineOrigin = 3;   // 0: Top, 1: Crosshair, 2: Bottom, 3: Count hub
    bool hideBots = false;
    bool teamId = false;
    bool playerId = false;
    bool playerCount = false;
    float espRangeMeters = 400.0f; // [50 .. 3000]
    bool ipadView = false;
    float cameraFovDeg = 95.0f;    // [80 .. 130]
};

struct AimSettings {
    bool masterAim = false;
    int triggerMode = 0;      // AimTriggerMode
    float smoothness = 4.0f;  // [1.0 .. 20.0]
    float fovRadiusPx = 120.0f; // [30.0 .. 450.0]
    float aimRangeMeters = 250.0f; // [10.0 .. 1000.0]
    float aimPower = 100.0f;  // [10.0 .. 100.0] Aim Assist %
    float silentDistMeters = 250.0f; // [10.0 .. 1000.0]
    bool autoFire = false;
    bool silentAim = false;
    bool silentAimV2 = false;
    bool silent360 = false;
    bool instantAim = false;
    bool visibleCheck = false;
    bool ignoreKnocked = false;
    bool targetBots = true;
    bool showFovCircle = false;
    int targetBone = 0;       // 0: Head, 1: Chest, 2: Pelvis
};

struct UiLayoutState {
    bool menuOpen = false;
    bool menuVisible = true;
    int activeTab = 0;        // 0..5 (ESP, Aim, Memory, Teleport, Hand, Settings)
    float uiScale = 1.0f;     // [0.70 .. 1.20]

    bool crosshair = false;
    bool watermark = true;
    bool hideRecording = false;
    bool showFeatureIcons = false;
    bool showTeleportIcons = false;
    bool engineStarted = false;

    float speedMultiplier = 2.0f; // [1.1 .. 50.0]

    // Floating widget saved normalized/absolute offsets (-1, -1 = auto default)
    float menuPosX = -1.0f;
    float menuPosY = -1.0f;
    float menuWidth = -1.0f;
    float menuHeight = -1.0f;

    float islandPosX = -1.0f;
    float islandPosY = -1.0f;

    float featurePos[4][2] = {
        {-1.0f, -1.0f}, {-1.0f, -1.0f}, {-1.0f, -1.0f}, {-1.0f, -1.0f}
    };
    float teleportPos[5][2] = {
        {-1.0f, -1.0f}, {-1.0f, -1.0f}, {-1.0f, -1.0f}, {-1.0f, -1.0f}, {-1.0f, -1.0f}
    };
    float autoFirePos[2] = {-1.0f, -1.0f};
    float hideMenuPos[2] = {-1.0f, -1.0f};

    // Runtime backdrop rects communicated to RyomenXOverlayView UIKit blurs
    float menuBackdropX = 0.0f, menuBackdropY = 0.0f, menuBackdropW = 0.0f, menuBackdropH = 0.0f;
    bool menuBackdropActive = false;

    float hubBackdropX = 0.0f, hubBackdropY = 0.0f, hubBackdropW = 0.0f, hubBackdropH = 0.0f;
    bool hubBackdropActive = false;
};

struct OverlayEntity {
    bool isBot = false;
    bool isKnocked = false;
    bool visible = false;
    bool onScreen = false;
    int teamId = 0;
    uint64_t playerId = 0;
    float health = 100.0f;
    float maxHealth = 100.0f;
    float distanceMeters = 0.0f;
    float offscreenAngleRad = 0.0f;
    float minX = 0.0f, minY = 0.0f, maxX = 0.0f, maxY = 0.0f;
    float headX = 0.0f, headY = 0.0f;
    float bonePos[16][2] = {};
    bool boneValid[16] = {};
    std::string name;
};

struct PickerItemEntry {
    int id = 0;
    std::string label;
};

struct PlayerTargetEntry {
    uint64_t id = 0;
    std::string label;
};

// Host backend adapter interface implemented outside the UI module.
// When `ctx.backend` is nullptr, all UI menus/tabs render safely with default state.
struct IHostBackend {
    virtual ~IHostBackend() = default;

    // Engine & State
    virtual void TickFrame(float screenW, float screenH, float dt) = 0;
    virtual const std::vector<OverlayEntity>& GetEntities() = 0;
    virtual void SetEngineEnabled(bool enabled) = 0;
    virtual void SetIpadView(bool enabled, float fovDeg) = 0;
    virtual void ResetAllSettings() = 0;

    // Memory features
    virtual FeatureStatus GetMemoryFeatureStatus(MemoryFeature feature) = 0;
    virtual bool RequestMemoryFeature(MemoryFeature feature, bool enable, float param = 1.0f) = 0;
    virtual void SetSpeedMultiplier(float multiplier) = 0;
    virtual std::string GetAmmoDiagnosticReport() { return std::string(); }
    virtual const char* GetMemoryFeatureName(MemoryFeature feature) = 0;

    // Custom toggles not indexed directly via MemoryFeature enum (Fly/Underground/PlaneFire)
    virtual bool GetFlyEnabled() = 0;
    virtual void SetFlyEnabled(bool enabled) = 0;
    virtual void SetFlyVerticalInput(float dir) { (void)dir; }
    virtual bool GetUndergroundEnabled() = 0;
    virtual void SetUndergroundEnabled(bool enabled) = 0;
    virtual bool GetPlaneFireEnabled() = 0;
    virtual void SetPlaneFireEnabled(bool enabled) = 0;

    // Teleport & Locks
    virtual bool HasSavedLocation() = 0;
    virtual bool ExecuteTeleportAction(const char* action, const char* target, int arg) = 0;
    virtual std::vector<PickerItemEntry> GetTeleportItems() = 0;
    virtual std::string GetSelectedItemName() = 0;
    virtual void SelectTeleportItem(int itemId) = 0;
    virtual bool GetMapTeleportEnabled() = 0;
    virtual void SetMapTeleportEnabled(bool enabled) = 0;
    virtual std::vector<PlayerTargetEntry> GetLockablePlayers() = 0;
    virtual uint64_t GetLockedPlayerId() = 0;
    virtual void SetLockedPlayerId(uint64_t id) = 0;
    virtual bool IsLockActive(const char* kind) = 0; // "player" or "airplane"
    virtual bool GetIgnoreBotsInLock() = 0;
    virtual void SetIgnoreBotsInLock(bool ignore) = 0;

    // Hand weapon selector
    virtual int GetSelectedHandSlot() = 0;
    virtual bool IsHandOverrideEnabled() = 0;
    virtual void DisableHandOverride() = 0;
    virtual bool SelectHandSlot(int slot) = 0;
    virtual const char* GetHandSlotName(int slot) = 0;
};

struct UiContext {
    UiLayoutState layout;
    EspSettings esp;
    AimSettings aim;
    void* brandTextureId = nullptr; // id<MTLTexture> cast for ImGui::Image

    std::string toastText;
    double toastStartTime = -10.0;

    IHostBackend* backend = nullptr;
};

UiContext& GetContext();

} // namespace IosUIBridge
