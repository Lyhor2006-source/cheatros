#import "IosGameBridge.h"
#import "IosPythonRuntime.h"
#import "IosUI.h"
#import "MemoryCheats.h"
#import "RosPayloadData.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

namespace IosGameBridge {

namespace {

class HostBackendImpl final : public IosUIBridge::IHostBackend {
public:
    void InitializeStorage() {
        NSArray<NSString*>* dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString* base = dirs.firstObject ?: NSTemporaryDirectory();
        NSString* dir = [base stringByAppendingPathComponent:@"RyomenX"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        baseDir_ = [dir UTF8String] ? [dir UTF8String] : "/tmp";
        espPath_ = baseDir_ + "/esp.txt";
        cfgPath_ = baseDir_ + "/aim_cfg.txt";
    }

    void TickFrame(float screenW, float screenH, float dt) override {
        (void)dt;
        auto& ctx = IosUIBridge::GetContext();

        // Auto-enable engine on first valid display if ESP or Aim is enabled
        if (!autoStarted_) {
            autoStarted_ = true;
            if (ctx.esp.masterEsp || ctx.aim.masterAim) {
                ctx.layout.engineStarted = true;
            }
        }

        // Apply pending Native memory freezes
        MemoryCheats::Tick();

        const bool wantRuntime =
            ctx.layout.engineStarted ||
            ctx.esp.masterEsp ||
            ctx.aim.masterAim ||
            ctx.esp.ipadView ||
            MemoryCheats::GetFlyEnabled() ||
            MemoryCheats::GetUndergroundEnabled() ||
            MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::SpeedHack).enabled ||
            MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::WallV1).enabled ||
            MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::WallV2).enabled ||
            MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::NoFallDamage).enabled ||
            MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::NoGrass).enabled ||
            MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::IpadView).enabled ||
            MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::ClearFog).enabled ||
            MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::NoRecoil).enabled ||
            MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::SuperJump).enabled ||
            MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::ZeroGravity).enabled ||
            MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::AutoReload).enabled ||
            MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::UnlimitedAmmo).enabled ||
            MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::HealerAim).enabled;

        if (!wantRuntime) {
            entities_.clear();
            lockablePlayers_.clear();
            inBattle_ = false;
            lastEspData_.clear();
            return;
        }

        ++tickCount_;
        if (tickCount_ % 10 == 1) {
            WriteAimConfig(screenW, screenH);
        }

        // Inject BigWorld Python runtime once BigWorld Py_IsInitialized() is ready
        if (!payloadInjected_ && (tickCount_ == 1 || tickCount_ % 60 == 0)) {
            TryInjectPayload();
        }

        if (payloadInjected_) {
            RefreshEspFrame(screenW, screenH);
        }
    }

    const std::vector<IosUIBridge::OverlayEntity>& GetEntities() override {
        return entities_;
    }

    void SetEngineEnabled(bool enabled) override {
        auto& ctx = IosUIBridge::GetContext();
        ctx.layout.engineStarted = enabled;
        if (!enabled) {
            entities_.clear();
            lockablePlayers_.clear();
            inBattle_ = false;
            lastEspData_.clear();
            WriteAimConfig(844.0f, 390.0f);
            IosUI::PushToast("Engine paused");
        } else {
            payloadInjected_ = false;
            TryInjectPayload();
            IosUI::PushToast(payloadInjected_ ? "Engine active" : "Waiting for game match");
        }
    }

    std::string CloneEquippedAmmo() override {
        if (!payloadInjected_) {
            IosUI::PushToast("Enter match first");
            return "Enter match first";
        }
        const std::string resultPath = baseDir_ + "/clone_ammo.txt";
        std::remove(resultPath.c_str());
        if (!IosPythonRuntime::Execute("_pb_clone_equipped_ammo()\n")) {
            IosUI::PushToast("Clone Ammo unavailable");
            return "Clone Ammo unavailable";
        }
        FILE* fp = std::fopen(resultPath.c_str(), "rb");
        if (!fp) {
            IosUI::PushToast("Clone Ammo result missing");
            return "Clone Ammo result missing";
        }
        char line[128] = {};
        const bool read = std::fgets(line, sizeof(line), fp) != nullptr;
        std::fclose(fp);
        int before = 0, after = 0;
        if (read && std::sscanf(line, "OK %d %d", &before, &after) == 2) {
            char toast[64];
            std::snprintf(toast, sizeof(toast), "Ammo %d -> %d", before, after);
            IosUI::PushToast(toast);
            return toast;
        }
        if (read && std::strncmp(line, "ERR ", 4) == 0) {
            line[std::strcspn(line, "\r\n")] = 0;
            IosUI::PushToast(line + 4);
            return line + 4;
        } else {
            IosUI::PushToast("Clone Ammo failed");
            return "Clone Ammo failed";
        }
    }

    std::string GetCloneAmmoDiagnostic() override {
        const std::string path = baseDir_ + "/clone_ammo_diag.txt";
        FILE* fp = std::fopen(path.c_str(), "rb");
        if (!fp) return {};
        char buf[65537] = {};
        const size_t read = std::fread(buf, 1, sizeof(buf) - 1, fp);
        std::fclose(fp);
        return std::string(buf, read);
    }

    void SetIpadView(bool enabled, float fovDeg) override {
        auto& ctx = IosUIBridge::GetContext();
        ctx.esp.ipadView = enabled;
        ctx.esp.cameraFovDeg = std::clamp(fovDeg, 80.0f, 130.0f);
        MemoryCheats::RequestFeature(IosUIBridge::MemoryFeature::IpadView, enabled, 1.0f);
        WriteAimConfig(lastW_, lastH_);
    }

    void ResetAllSettings() override {
        auto& ctx = IosUIBridge::GetContext();
        ctx.esp = IosUIBridge::EspSettings{};
        ctx.aim = IosUIBridge::AimSettings{};
        ctx.layout.speedMultiplier = 2.0f;
        MemoryCheats::SetFlyEnabled(false);
        MemoryCheats::SetUndergroundEnabled(false);
        flyVerticalInput_.store(0.0f, std::memory_order_relaxed);
        hasSavedLoc_ = false;
        lockedPlayerId_ = 0;
        playerLockActive_ = false;
        airplaneLockActive_ = false;
        WriteAimConfig(lastW_, lastH_);
        IosUI::PushToast("Settings reset");
    }

    IosUIBridge::FeatureStatus GetMemoryFeatureStatus(IosUIBridge::MemoryFeature feature) override {
        return MemoryCheats::GetStatus(feature);
    }

    bool RequestMemoryFeature(IosUIBridge::MemoryFeature feature, bool enable, float param) override {
        const bool ok = MemoryCheats::RequestFeature(feature, enable, param);
        WriteAimConfig(lastW_, lastH_);
        return ok;
    }

    void SetSpeedMultiplier(float multiplier) override {
        MemoryCheats::SetSpeedMultiplier(multiplier);
        WriteAimConfig(lastW_, lastH_);
    }

    const char* GetMemoryFeatureName(IosUIBridge::MemoryFeature feature) override {
        return MemoryCheats::GetFeatureName(feature);
    }

    bool GetFlyEnabled() override {
        return MemoryCheats::GetFlyEnabled();
    }

    void SetFlyEnabled(bool enabled) override {
        MemoryCheats::SetFlyEnabled(enabled);
        if (!enabled) {
            flyVerticalInput_.store(0.0f, std::memory_order_relaxed);
        }
        WriteAimConfig(lastW_, lastH_);
    }

    void SetFlyVerticalInput(float dir) override {
        const float clamped = std::clamp(dir, -1.0f, 1.0f);
        if (std::fabs(clamped - flyVerticalInput_.load(std::memory_order_relaxed)) > 0.01f) {
            flyVerticalInput_.store(clamped, std::memory_order_relaxed);
            WriteAimConfig(lastW_, lastH_);
        }
    }

    bool GetUndergroundEnabled() override {
        return MemoryCheats::GetUndergroundEnabled();
    }

    void SetUndergroundEnabled(bool enabled) override {
        MemoryCheats::SetUndergroundEnabled(enabled);
        WriteAimConfig(lastW_, lastH_);
    }

    bool GetPlaneFireEnabled() override { return false; }
    void SetPlaneFireEnabled(bool enabled) override {
        (void)enabled;
        IosUI::PushToast("Plane Fire not bundled");
    }

    bool HasSavedLocation() override { return hasSavedLoc_; }

    bool ExecuteTeleportAction(const char* action, const char* target, int arg) override {
        (void)target;
        (void)arg;
        if (!action) return false;
        const std::string act(action);

        if (act == "save") {
            if (!inBattle_) {
                IosUI::PushToast("Enter match to save location");
                return false;
            }
            savedX_ = localX_;
            savedY_ = localY_;
            savedZ_ = localZ_;
            hasSavedLoc_ = true;
            IosUI::PushToast("Location saved");
            return true;
        }

        if (act == "saved") {
            if (!hasSavedLoc_) {
                IosUI::PushToast("No saved location");
                return false;
            }
            if (!payloadInjected_) {
                IosUI::PushToast("Match Python runtime not active");
                return false;
            }
            char cmd[128];
            std::snprintf(cmd, sizeof(cmd), "_pb_teleport_to(%.4f, %.4f, %.4f)\n", savedX_, savedY_, savedZ_);
            const bool ok = IosPythonRuntime::Execute(cmd);
            IosUI::PushToast(ok ? "Teleported to saved" : "Teleport failed");
            return ok;
        }

        if (act == "parachute_jump") {
            if (!payloadInjected_) {
                IosUI::PushToast("Enter airplane first");
                return false;
            }
            const bool ok = IosPythonRuntime::Execute("_pb_jump_from_plane()\n");
            IosUI::PushToast(ok ? "Jump triggered" : "Jump unavailable");
            return ok;
        }

        if (act == "lock" || act == "unlock") {
            if (target && std::strcmp(target, "airplane") == 0) {
                airplaneLockActive_ = false;
                IosUI::PushToast("Airplane Lock not bundled");
                return false;
            }
            if (act == "unlock") {
                playerLockActive_ = false;
                return true;
            }
            if (!inBattle_ || entities_.empty()) {
                IosUI::PushToast("No enemy target in match");
                return false;
            }
            uint64_t targetId = lockedPlayerId_;
            if (targetId == 0) {
                float bestDist = 1e9f;
                for (const auto& e : entities_) {
                    if (ignoreBotsInLock_ && e.isBot) continue;
                    if (e.distanceMeters < bestDist) {
                        bestDist = e.distanceMeters;
                        targetId = e.playerId;
                    }
                }
            }
            if (targetId == 0) {
                IosUI::PushToast("No matching enemy");
                return false;
            }
            char cmd[96];
            std::snprintf(cmd, sizeof(cmd), "_pb_teleport_entity(%llu)\n", static_cast<unsigned long long>(targetId));
            const bool ok = IosPythonRuntime::Execute(cmd);
            IosUI::PushToast(ok ? "Teleported to enemy" : "Target unavailable");
            return ok;
        }

        if (act == "item") {
            IosUI::PushToast("Item Teleport not bundled");
            return false;
        }

        return false;
    }

    std::vector<IosUIBridge::PickerItemEntry> GetTeleportItems() override { return {}; }
    std::string GetSelectedItemName() override { return {}; }
    void SelectTeleportItem(int itemId) override {
        (void)itemId;
        IosUI::PushToast("Item Teleport not bundled");
    }
    bool GetMapTeleportEnabled() override { return false; }
    void SetMapTeleportEnabled(bool enabled) override {
        (void)enabled;
        IosUI::PushToast("Map Teleport not bundled");
    }

    std::vector<IosUIBridge::PlayerTargetEntry> GetLockablePlayers() override {
        return lockablePlayers_;
    }

    uint64_t GetLockedPlayerId() override { return lockedPlayerId_; }
    void SetLockedPlayerId(uint64_t id) override { lockedPlayerId_ = id; }

    bool IsLockActive(const char* kind) override {
        if (kind && std::strcmp(kind, "airplane") == 0) return airplaneLockActive_;
        return playerLockActive_;
    }

    bool GetIgnoreBotsInLock() override { return ignoreBotsInLock_; }
    void SetIgnoreBotsInLock(bool ignore) override { ignoreBotsInLock_ = ignore; }

    int GetSelectedHandSlot() override { return -1; }
    bool IsHandOverrideEnabled() override { return false; }
    void DisableHandOverride() override {}
    bool SelectHandSlot(int slot) override {
        (void)slot;
        IosUI::PushToast("Hand Override not bundled");
        return false;
    }
    const char* GetHandSlotName(int slot) override {
        static const char* kNames[5] = {"AWM", "RPG", "BARRETT", "BOW", "CROSSBOW"};
        return (slot >= 0 && slot < 5) ? kNames[slot] : "Weapon";
    }

private:
    void TryInjectPayload() {
        if (baseDir_.empty()) {
            InitializeStorage();
        }
        if (!IosPythonRuntime::IsPythonInitialized()) {
            return;
        }
        std::string preamble = "_RYOMENX_DIR = '";
        preamble += baseDir_;
        preamble += "'\n";
        std::string script = preamble + std::string(RosPayload::kPayloadPython, RosPayload::kPayloadPythonLength);
        std::string err;
        if (IosPythonRuntime::Execute(script, &err)) {
            payloadInjected_ = true;
        }
    }

    void WriteAimConfig(float screenW, float screenH) {
        if (cfgPath_.empty()) return;
        lastW_ = std::max(screenW, 1.0f);
        lastH_ = std::max(screenH, 1.0f);
        const float scale = static_cast<float>([UIScreen mainScreen].scale);
        const float fbW = lastW_ * std::max(scale, 1.0f);
        const float fbH = lastH_ * std::max(scale, 1.0f);

        const auto& ctx = IosUIBridge::GetContext();
        const auto& aim = ctx.aim;
        const auto& esp = ctx.esp;
        const auto& lay = ctx.layout;

        const float assistPct = std::clamp(aim.aimPower, 10.0f, 100.0f);
        const int speedOn = MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::SpeedHack).enabled ? 1 : 0;
        const int noFallOn = MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::NoFallDamage).enabled ? 1 : 0;
        const int camWideOn = MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::IpadView).enabled ? 1 : 0;
        const int autoReloadOn = MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::AutoReload).enabled ? 1 : 0;
        const int unlimitedAmmoOn = MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::UnlimitedAmmo).enabled ? 1 : 0;
        const int healerAimOn = MemoryCheats::GetStatus(IosUIBridge::MemoryFeature::HealerAim).enabled ? 1 : 0;

        char buf[1024];
        std::snprintf(
            buf, sizeof(buf),
            "%d %d %.2f %.2f %.2f %d %d %d %.2f %.2f %.2f 0 0 0 0 1 %.2f %.2f 0 0 %.2f %.2f 0 %.2f 1 %d %d %d %.2f %d %.2f 0 %d 0 0 0 %d %d 0 0 0.00 0 0 %d %d %d\n",
            aim.masterAim ? 1 : 0,                                  // c[0]
            aim.triggerMode,                                        // c[1]
            aim.fovRadiusPx,                                        // c[2]
            aim.smoothness,                                         // c[3]
            assistPct,                                              // c[4] Aim Assist 10..100%
            aim.visibleCheck ? 1 : 0,                               // c[5]
            aim.ignoreKnocked ? 1 : 0,                              // c[6]
            aim.targetBone,                                         // c[7]
            lastW_,                                                 // c[8]
            lastH_,                                                 // c[9]
            aim.aimRangeMeters,                                     // c[10]
            fbW, fbH,                                               // c[16..17]
            fbW, fbH,                                               // c[20..21]
            std::clamp(aim.aimRangeMeters, 5.0f, 500.0f),           // c[23]
            (!aim.targetBots || esp.hideBots) ? 1 : 0,              // c[25]
            esp.skeleton ? 1 : 0,                                   // c[26]
            esp.ipadView ? 1 : 0,                                   // c[27]
            esp.cameraFovDeg,                                       // c[28]
            speedOn,                                                // c[29]
            lay.speedMultiplier,                                    // c[30]
            noFallOn,                                               // c[32]
            0,                                                      // c[36] reserved; Fast Parachute uses native memory patch
            camWideOn,                                              // c[37]
            autoReloadOn,                                           // c[43]
            unlimitedAmmoOn,                                        // c[44]
            healerAimOn);                                           // c[45]

        const std::string tmpPath = cfgPath_ + ".new";
        FILE* fp = std::fopen(tmpPath.c_str(), "wb");
        if (fp) {
            std::fwrite(buf, 1, std::strlen(buf), fp);
            std::fclose(fp);
            std::rename(tmpPath.c_str(), cfgPath_.c_str());
        }
    }

    void RefreshEspFrame(float screenW, float screenH) {
        if (espPath_.empty()) return;
        FILE* fp = std::fopen(espPath_.c_str(), "rb");
        if (!fp) return;

        std::fseek(fp, 0, SEEK_END);
        const long fsize = std::ftell(fp);
        if (fsize <= 0 || fsize > 1024 * 1024) {
            std::fclose(fp);
            entities_.clear();
            lockablePlayers_.clear();
            inBattle_ = false;
            lastEspData_.clear();
            return;
        }
        std::fseek(fp, 0, SEEK_SET);
        std::string data(static_cast<size_t>(fsize), '\0');
        const size_t nread = std::fread(&data[0], 1, static_cast<size_t>(fsize), fp);
        std::fclose(fp);
        data.resize(nread);

        if (data == lastEspData_ && screenW == lastEspW_ && screenH == lastEspH_) return;
        lastEspData_ = data;
        lastEspW_ = screenW;
        lastEspH_ = screenH;

        ParseEspBuffer(data, screenW, screenH);
    }

    void ParseEspBuffer(const std::string& data, float screenW, float screenH) {
        entities_.clear();
        lockablePlayers_.clear();

        const float scale = std::max(1.0f, static_cast<float>([UIScreen mainScreen].scale));
        auto mapPoint = [&](float x, float y) -> std::pair<float, float> {
            if (std::fabs(x) <= 2.0f && std::fabs(y) <= 2.0f) {
                return {x * screenW, y * screenH};
            }
            return {x / scale, y / scale};
        };

        std::istringstream stream(data);
        std::string line;
        if (!std::getline(stream, line)) {
            inBattle_ = false;
            return;
        }

        int hdrCount = 0;
        float me6[9] = {};
        int mode = 0, bs = 0, trig = 0;
        std::istringstream hdrStream(line);
        if (!(hdrStream >> hdrCount)) {
            inBattle_ = false;
            return;
        }
        if (!(hdrStream >> me6[0] >> me6[1] >> me6[2] >> me6[3] >> me6[4] >> me6[5] >> me6[6] >> me6[7] >> me6[8] >> mode >> bs >> trig)) {
            inBattle_ = false;
            return;
        }
        inBattle_ = true;
        localX_ = me6[0];
        localY_ = me6[1];
        localZ_ = me6[2];

        const float viewYaw = std::atan2(me6[6], me6[8]);

        while (std::getline(stream, line)) {
            if (line.empty()) continue;
            const size_t sep1 = line.find('|');
            if (sep1 == std::string::npos) continue;
            const size_t sep2 = line.find('|', sep1 + 1);

            const std::string mainPart = line.substr(0, sep1);
            const std::string bonePart = (sep2 != std::string::npos)
                ? line.substr(sep1 + 1, sep2 - sep1 - 1)
                : line.substr(sep1 + 1);

            std::istringstream ms(mainPart);
            float fsx = 0, fsy = 0, hsx = 0, hsy = 0;
            int on = 0;
            float px = 0, py = 0, pz = 0, vx = 0, vy = 0, vz = 0;
            int hp = 0, mhp = 100, enemy = 0, vis = 0;
            float distRaw = 0;
            int knocked = 0, bot = 0, team = 0, sh = 0, msh = 0, inVeh = 0;
            uint64_t eid = 0;
            std::string nick;

            if (!(ms >> fsx >> fsy >> hsx >> hsy >> on >> px >> py >> pz >> vx >> vy >> vz
                     >> hp >> mhp >> enemy >> vis >> distRaw >> knocked >> bot >> team
                     >> sh >> msh >> inVeh >> eid >> nick)) {
                continue;
            }
            if (enemy == 0) continue;

            IosUIBridge::OverlayEntity ent;
            ent.isBot = (bot != 0);
            ent.isKnocked = (knocked != 0);
            ent.visible = (vis != 0);
            ent.onScreen = (on != 0);
            ent.teamId = team;
            ent.playerId = eid;
            ent.health = static_cast<float>(std::max(0, hp));
            ent.maxHealth = static_cast<float>(std::max(1, mhp));
            ent.distanceMeters = distRaw / 10.0f;
            ent.name = nick;

            const float worldYaw = std::atan2(px - localX_, pz - localZ_);
            ent.offscreenAngleRad = worldYaw - viewYaw;

            auto [fx, fy] = mapPoint(fsx, fsy);
            auto [hx, hy] = mapPoint(hsx, hsy);
            const float boxH = std::max(8.0f, std::fabs(fy - hy));
            const float halfW = boxH * 0.28f;
            const float cx = (fx + hx) * 0.5f;
            ent.minX = cx - halfW;
            ent.maxX = cx + halfW;
            ent.minY = std::min(hy, fy);
            ent.maxY = std::max(hy, fy);
            ent.headX = hx;
            ent.headY = hy;
            // The game can return projected points outside the viewport.
            // Keep those entities for edge arrows, not boxes or clamped labels.
            ent.onScreen = ent.onScreen && std::isfinite(cx) &&
                std::isfinite(ent.minY) && std::isfinite(ent.maxY) &&
                cx >= 0.0f && cx <= screenW &&
                ent.maxY >= 0.0f && ent.minY <= screenH &&
                boxH <= screenH * 2.0f;

            // Parse up to 16 bones separated by ';'
            std::istringstream bStream(bonePart);
            std::string bToken;
            int bIdx = 0;
            while (bIdx < 16 && std::getline(bStream, bToken, ';')) {
                int valid = 0;
                float bx = 0.0f, by = 0.0f;
                std::istringstream singleBone(bToken);
                if (singleBone >> valid >> bx >> by) {
                    if (valid != 0) {
                        auto [sbx, sby] = mapPoint(bx, by);
                        ent.boneValid[bIdx] = true;
                        ent.bonePos[bIdx][0] = sbx;
                        ent.bonePos[bIdx][1] = sby;
                    }
                }
                ++bIdx;
            }

            IosUIBridge::PlayerTargetEntry pt;
            pt.id = eid;
            char lbl[96];
            std::snprintf(lbl, sizeof(lbl), "%s (%.0fm)", nick.c_str(), ent.distanceMeters);
            pt.label = lbl;
            lockablePlayers_.push_back(std::move(pt));

            entities_.push_back(std::move(ent));
        }
    }

    std::string baseDir_;
    std::string espPath_;
    std::string cfgPath_;
    std::string lastEspData_;
    float lastEspW_ = 0.0f;
    float lastEspH_ = 0.0f;

    std::vector<IosUIBridge::OverlayEntity> entities_;
    std::vector<IosUIBridge::PlayerTargetEntry> lockablePlayers_;
    std::atomic<float> flyVerticalInput_{0.0f};

    uint64_t tickCount_ = 0;
    bool autoStarted_ = false;
    bool payloadInjected_ = false;
    bool inBattle_ = false;
    bool hasSavedLoc_ = false;
    float localX_ = 0.0f, localY_ = 0.0f, localZ_ = 0.0f;
    float savedX_ = 0.0f, savedY_ = 0.0f, savedZ_ = 0.0f;
    float lastW_ = 844.0f, lastH_ = 390.0f;

    uint64_t lockedPlayerId_ = 0;
    bool playerLockActive_ = false;
    bool airplaneLockActive_ = false;
    bool ignoreBotsInLock_ = true;
};

HostBackendImpl& GetBackendInstance() {
    static HostBackendImpl instance;
    return instance;
}

} // namespace

void Initialize() {
    GetBackendInstance().InitializeStorage();
    MemoryCheats::Initialize();
    IosPythonRuntime::Resolve();
}

void Shutdown() {
    MemoryCheats::Shutdown();
}

IosUIBridge::IHostBackend& Backend() {
    return GetBackendInstance();
}

} // namespace IosGameBridge
