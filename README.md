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

Unlimited Ammo maintains a local reserve (`ammo_box_bullet_count`) and requests one native reload when the selected magazine empties. The game controls reload timing, shell loading, magazine counts, and HUD updates. No timeout synthesizes ammunition. Rejected or cancelled empty reloads stop further requests until the feature is reset or the selected weapon changes. A request without observable completion remains pending. Local reserve changes do not update bag inventory.
Healer Aim uses the existing ray hook to select visible teammates inside the configured camera FOV without rotating the camera.

Fast Parachute scans in the background while disabled and remembers the original target and adjacent marker. When enabled during a match, it validates the cached address and marker before patching; if validation fails, it stays enabled and retries every two seconds. It reports active only after a patch applies.
