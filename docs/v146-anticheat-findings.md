# ROS Hariki iOS v146 Ultra: anti-cheat findings

Target: `ROS-Hariki-iOS-v146-Ultra-8GB-unsigned.ipa`

- IPA SHA-256: `b74cdfb5a238bcee0eb6b6cf3e6fe263cf2c8d6bbb20f37b1490bf3b1bdaffe2`
- `Payload/client.app/client` SHA-256: `27ebb92b0d774bef1d56c21fccf339a58be101ca835c7eb710b4ef94b5c47fce`
- Format: arm64 Mach-O. `__TEXT` maps file offset 0 to preferred VM address `0x100000000`.

## Observed native registration table

The client contains NUL-terminated API names and a table of 32-byte records, each with a name pointer followed by a code pointer. The table entry for `anti_cheat_check` starts at file offset `0x3851480` (preferred VA `0x103851480`). These addresses are preferred VM addresses, **not** ASLR runtime addresses.

| API name | Table record file offset | Wrapper preferred VA | Wrapper file offset | First 16 bytes |
|---|---:|---:|---:|---|
| `anti_cheat_check` | `0x3851480` | `0x10104cd74` | `0x104cd74` | `ff4301d1fd7b04a9fd030191e00301aa` |
| `mobile_acsdk_check` | `0x3851580` | `0x10104d4bc` | `0x104d4bc` | `ff0301d1f44f02a9fd7b03a9fdc30091` |
| `inspect_loaded_modules` | `0x3851600` | `0x10104d64c` | `0x104d64c` | `fd7bbfa9fd030091004e2c94000440f9` |

`anti_cheat_check` parses a Python argument tuple, obtains an internal object, and calls a method through its vtable at offset `0x2a0`. `mobile_acsdk_check` calls a method at vtable offset `0x330`; `inspect_loaded_modules` calls a method at offset `0x2e0`. These are observed wrapper operations, not proof that any one method ran during the reported ban.

The shared helper at preferred VA `0x101b60e54` reads a process-local singleton pointer from preferred VA `0x1044d33a0`; the wrappers then read the object at singleton offset `+8` before dispatch. The concrete vtable pointer is populated at runtime and is not established by these file bytes. A wrapper-only return patch would therefore be an unverified change to the Python API contract, not a verified bypass of the underlying check.

## Limits of current evidence

- The exact text `iOS anti-cheat`, `This account is banned`, and `Cheating` does not appear in the uncompressed members of this IPA (all 1,214 members below 70 MB checked; one larger resource skipped). This does not establish where the login message originates.
- `script.npk` is an NXPK archive with 3,983 index records. The local NXPK reader parses its index; the script entry bodies do not expose plain anti-cheat call sites. No decompiled script call path has been verified.
- REA opened the IPA and arm64 client, but its native string and xref queries did not return in this session. The registration table and wrapper instructions above were measured directly from the named client bytes using Python and Capstone.
- There is no runtime anti-cheat trace, server request/response, or exact injected IPA for the banned session. The screenshot shows an account ban message, but cannot identify a client check that caused it.
- These native client wrappers alone do not justify a bypass patch. A patch to one wrapper could leave other checks or server-side enforcement intact.

## Hariki framework detection path and experimental patch

Further inspection of the same IPA found `Payload/client.app/Frameworks/HK.framework/HK` (SHA-256 `2b4b5a6facc4196352f1ef9dde1fe89622bbf2df864be72472257eda639bbb31`). Its arm64 `__TEXT` maps file offset 0 to preferred VA 0.

- The `__init_offsets` section contains `0x4000`, so the function beginning at `0x4000` is an HK load initializer. At file offset `0x4014`, bytes `a0c80194` call `__dyld_register_func_for_add_image` with callback address `0x4068`. The callback invokes `dladdr` and checks each loaded image path against permitted path fragments.
- At `0x5324`–`0x5348`, the framework constructs the reason string `unauthorized_dylib_injected`, then calls the routine at `0x537c`. This matches the visible `una...` prefix in the user screenshot; the screenshot does not expose the rest of the message.
- Four direct call sites (`0x49cc`, `0x5250`, `0x52d4`, `0x5350`) call `0x537c`. That routine prepares a request using the embedded Hariki auto-ban URL. It is a reporting path, though no live request was captured here.
- An exact-build patcher at `tools/patch_v146_hk_anticheat.py` replaces the callback registration call with an ARM64 NOP (`1f2003d5`) and the first instruction of the report routine (`fc6fbaa9`) with ARM64 RET (`c0035fd6`). The patcher refuses any other IPA or HK digest.
- Static validation: the patched IPA contains the same 1,215 members in the same order; only `HK.framework/HK` differs; ZIP integrity passes; Capstone disassembles the replacement bytes as `nop` and `ret`. Patched IPA SHA-256: `6fd4b4a74790ecb5435caa9ccb6cc6fe04989468c48ba6b0bff630a6ec56fd4b`.
- Review of the IPA found no `_CodeSignature` archive entries and no `LC_CODE_SIGNATURE` command in HK, consistent with the supplied unsigned package. The patched IPA still needs normal signing before iOS installation.

This verifies suppression of the measured Hariki image callback and report routine in file bytes. It does **not** establish that iOS code signing, other checks, server enforcement, or target gameplay will accept the modified IPA. Roll back with the unmodified original IPA.

## IPA with RosModV2UI embedded

`tools/inject_v146_dylib.py` embeds the last code-changing `RosModV2UI.dylib` build (SHA-256 `2ec429aabef3012a300d54bc1b53367d470b01cd05a60c3bdf083af683d80261`) in the patched IPA. It adds `Payload/client.app/Frameworks/RosModV2UI.dylib` and an `LC_LOAD_DYLIB` command for `@executable_path/Frameworks/RosModV2UI.dylib` to `client`. The output IPA SHA-256 is `00a46705abfd0a518b1a63002683d5bb866ab9f697a61cf289079658bce2d277`.

Validation found 1,216 ZIP members, with one added dylib and only `client` changed relative to the HK-patched IPA; ZIP integrity passed. The `client` contains an existing `LC_CODE_SIGNATURE` command whose signature is no longer valid after the load-command edit. The absence of a `_CodeSignature` ZIP member does not mean the Mach-O lacks a signature command. The IPA must be re-signed before installation, and target launch/gameplay has not been tested.

## Full client binary anti-cheat bypass (`tools/patch_v146_full_anticheat.py`)

Further disassembly and reverse engineering of `Payload/client.app/client` mapped the complete Python `game3d` module table (initialized at preferred VA `0x101047ef4` from table base `0x10384fb40`). The native wrappers were analyzed down to their ARM64 instructions and Python C API calling conventions:

1. **`is_outlaw_device` (VA `0x10104af70`, file offset `0x104af70`)**:
   - Instruction at `0x10104af90`: `csel x0, x9, x8, ne` (`2011889a`), where `x9` is `_Py_TrueStruct` (`0x1038e5e50`) and `x8` is `_Py_FalseStruct` (`0x1038e5e68`).
   - Patch: replaced with `mov x0, x8` (`e00308aa`).
   - Effect: Always returns `Py_False` with incremented refcount, completely neutralizing jailbreak/outlaw device detection.

2. **`inspect_loaded_modules` (VA `0x10104d64c`, file offset `0x104d64c`)**:
   - Instruction at `0x10104d664`: `blr x8` (`00013fd6`), which calls method `+0x2e0` to scan loaded dylibs.
   - Patch: replaced with `nop` (`1f2003d5`).
   - Effect: Dylib scan is skipped. Execution falls through to increment `_Py_NoneStruct` refcount and returns `Py_None` without error or violation of the Python contract.

3. **`mobile_acsdk_check` (VA `0x10104d4bc`, file offset `0x104d4bc`)**:
   - Instructions at `0x10104d4e0`: `add x8, sp, #8` (`e8230091`) and `blr x9` (`20013fd6`) dispatching method `+0x330`.
   - Patch: replaced with `str xzr, [sp, #8]` (`ff0700f9`) and `strb wzr, [sp, #0x1f]` (`ff7f0039`).
   - Effect: Zeroes out the stack-allocated SSO `std::string` buffer and skips check dispatch. `PyString_FromString` returns a clean empty string `""` without heap deallocation or exception.

4. **`anti_cheat_check` (VA `0x10104cd74`, file offset `0x104cddc`)**:
   - Instruction at `0x10104cddc`: `blr x8` (`00013fd6`), calling method `+0x2a0` which writes an 8-byte token into `[x29, #-0x10]`.
   - Patch: replaced with `stur xzr, [x29, #-0x10]` (`bf031ff8`).
   - Effect: Directly zeroes the 8-byte buffer and skips dispatch. `PyString_FromStringAndSize` returns an 8-byte null token `\0\0\0\0\0\0\0\0` cleanly.

5. **`check_graphic_states` (VA `0x10104d6e0`, file offset `0x104d710`)**:
   - Instruction at `0x10104d710`: `csel x0, x9, x8, ne` (`2011889a`), checking hooked graphics states/views.
   - Patch: replaced with `mov x0, x8` (`e00308aa`).
   - Effect: Always returns `Py_False`, neutralizing UI overlay and graphic context hook detection.

6. **`inspect_system_processes` (VA `0x10104d728`, file offset `0x104d740`)**:
   - Instruction at `0x10104d740`: `blr x8` (`00013fd6`).
   - Patch: replaced with `nop` (`1f2003d5`).
   - Effect: Skips system process inspection entirely.

7. **`inspect_system_windows` (VA `0x10104d760`, file offset `0x104d778`)**:
   - Instruction at `0x10104d778`: `blr x8` (`00013fd6`).
   - Patch: replaced with `nop` (`1f2003d5`).
   - Effect: Skips system window/overlay hierarchy inspection.

### Verified Full-Patched Builds

- `tools/patch_v146_full_anticheat.py` applies all 9 patches (2 in HK, 7 in client), with optional `--dylib` injection.
- Full-patched + RosModV2UI injected IPA: `ROS-Hariki-iOS-v146-Ultra-8GB-full-patched-RosModV2UI-unsigned.ipa` (SHA-256 `c61b49b5abd2e5aca6df23582f007eba8c3a9f1125c3be831597b6acf8387bee`).
  - Patched HK SHA-256: `345ad502ca8e80c4c145885bb3f4c2f93a0deb966ad3493eb83eee33ab13aace`
  - Patched client SHA-256: `c2e18aeb1344c61e73a3482019e859d6859859d9c4e9c633d992cb0e8de4c48a`

Reproduce the static mapping: verify both SHA-256 digests, parse the Mach-O `LC_SEGMENT_64` records for `__TEXT`, locate the `anti_cheat_check` string at client file offset `0x316254c`, then find its 64-bit little-endian preferred VA `0x10316254c` at `0x3851480`. The next 64-bit value in that table record is the wrapper VA. Disassemble its bytes as arm64 with Capstone.
