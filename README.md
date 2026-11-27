# RosModV2UI

Standalone iOS `arm64` Metal + Dear ImGui overlay `.dylib` (`RosModV2UI.dylib`).

- Self-contained standalone UI overlay module
- Bundled textures and fonts compiled directly into the dylib (`src/BrandAssetsData.cpp`) with optional disk override in `assets/`
- Automatic window attachment via `RyomenXAttachOverlayToKeyWindow()` (`ROSMODV2_DISABLE_AUTO_ATTACH` disables constructor auto-attach)
- Optional host hook integration via `IosUIBridge::IHostBackend` (`include/IosUIBridge.h`)

## GitHub Actions Cloud Build

Push to `main` (or run **Actions -> Build iOS UI Dylib -> Run workflow**) on `macos-latest` to compile `RosModV2UI.dylib` (`iphoneos` / `arm64`) and download it from the workflow artifacts.

## Embedded game payload

Edit `payload/RosPayload.py`, then run `python tools/embed_payload.py` before building. `src/RosPayloadData.cpp` is generated from that source. Run `python tools/smoke_reload.py` for the ammo/reload controller smoke check.

Unlimited Ammo keeps a local reserve (`ammo_box_bullet_count`) while magazine rounds decrease normally. It requests the game's reload once when the magazine empties, waits for the reload state to end, then fills the selected magazine to capacity. If the game never enters a reload state, a 2.25-second fallback refills locally. A failed magazine write leaves the HUD unchanged and stops repeat reload requests. Local reserve changes do not update bag inventory or persist across weapon swaps.
Healer Aim uses the existing ray hook to select visible teammates inside the configured camera FOV without rotating the camera.

Fast Parachute scans in the background while disabled and remembers the original target and adjacent marker. When enabled during a match, it validates the cached address and marker before patching; if validation fails, it stays enabled and retries every two seconds. It reports active only after a patch applies.
