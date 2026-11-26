# RosModV2UI

Standalone iOS `arm64` Metal + Dear ImGui overlay `.dylib` (`RosModV2UI.dylib`).

- Self-contained standalone UI overlay module
- Bundled textures and fonts compiled directly into the dylib (`src/BrandAssetsData.cpp`) with optional disk override in `assets/`
- Automatic window attachment via `RyomenXAttachOverlayToKeyWindow()` (`ROSMODV2_DISABLE_AUTO_ATTACH` disables constructor auto-attach)
- Optional host hook integration via `IosUIBridge::IHostBackend` (`include/IosUIBridge.h`)

## GitHub Actions Cloud Build

Push to `main` (or run **Actions -> Build iOS UI Dylib -> Run workflow**) on `macos-latest` to compile `RosModV2UI.dylib` (`iphoneos` / `arm64`) and download it from the workflow artifacts.
