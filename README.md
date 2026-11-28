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

Unlimited Ammo's previous synthetic-reserve implementation was removed after device testing showed repeated native reloads with empty inventory. The controller never fabricates reserve or magazine counts, and requests at most one native reload per empty-magazine cycle. Zero reserve reports refill unavailable. Native unlimited replenishment remains unresolved; the feature is not a working unlimited-ammo implementation. `ammo_status.txt` exposes counts and state; `ros_feature_diag.txt` records selected magazine fields and methods for diagnosing the native ammo-transfer path.
Healer Aim uses the existing ray hook to select visible teammates inside the configured camera FOV without rotating the camera.

Fast Parachute scans in the background while disabled and remembers the original target and adjacent marker. When enabled during a match, it validates the cached address and marker before patching; if validation fails, it stays enabled and retries every two seconds. It reports active only after a patch applies.
