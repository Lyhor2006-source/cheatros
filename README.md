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

Unlimited Ammo maintains infinite reserve ammunition (`ammo_box_bullet_count`), while allowing natural magazine bullet depletion on shots. Each gun executes its authentic in-game reload animation and timing uninterrupted without reload-loop locks.

Fast Parachute uses the native memory scan and reports active only after a patch applies. If its target allocation is not present yet, it stays enabled and retries every two seconds.
