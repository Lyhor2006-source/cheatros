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

Unlimited Ammo uses owned methods on the selected local magazine: each shot reduces the local count; the game's reload sequence calls `addBulletToMagazine` to transfer rounds at its native time. The transfer honors per-shell counts and magazine capacity. It maintains a virtual reserve while replacing the native inventory-consuming transfer; there is no timeout refill and no camera or reload-speed change. Hooks and the virtual reserve are restored when disabled, switched, or leaving a match. Local behavior does not establish server acceptance. `ammo_status.txt` exposes counts and state; `ros_feature_diag.txt` records selected magazine fields and methods. Run `python tools/smoke_local_ammo_cycle.py` for 30-, 5-, and 1-round regression cases.
Healer Aim aligns the camera toward visible teammates when the healer gun is equipped, independently of enemy Aim Assist. It prioritizes downed, injured, then healthy teammates within the camera view and aim range, aiming at the chest. Healer shots use native firing; enemy ray redirection is disabled while healer assistance is active. Torso visibility is queried at the actual chest aim point when native geometry queries are available. Target selection retains an eligible equal-priority teammate through small screen movements and releases it for obstruction, range, or a higher-priority target. Status reports selected targets and camera rotation.

Fast Parachute scans in the background while disabled and remembers the original target and adjacent marker. When enabled during a match, it validates the cached address and marker before patching; if validation fails, it stays enabled and retries every two seconds. It reports active only after a patch applies.
