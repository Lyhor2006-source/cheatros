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
- No binary patch or bypass is justified by these findings. A patch to one wrapper could leave other checks or server-side enforcement intact.

Reproduce the static mapping: verify both SHA-256 digests, parse the Mach-O `LC_SEGMENT_64` records for `__TEXT`, locate the `anti_cheat_check` string at client file offset `0x316254c`, then find its 64-bit little-endian preferred VA `0x10316254c` at `0x3851480`. The next 64-bit value in that table record is the wrapper VA. Disassemble its bytes as arm64 with Capstone.
