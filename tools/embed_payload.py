"""Regenerate RosPayloadData.cpp from the editable BigWorld Python payload."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "payload" / "RosPayload.py"
OUTPUT = ROOT / "src" / "RosPayloadData.cpp"


def render(data):
    data += b"\0"
    rows = []
    for offset in range(0, len(data), 32):
        chunk = data[offset:offset + 32]
        rows.append("    " + ", ".join("static_cast<char>(0x%02x)" % byte for byte in chunk) + ",")
    return (
        '#include "RosPayloadData.h"\n\n'
        'namespace RosPayload {\n\n'
        f'const std::size_t kPayloadPythonLength = {len(data)}u;\n\n'
        + 'const char kPayloadPython[] = {\n'
        + "\n".join(rows)
        + '\n};\n\n} // namespace RosPayload\n'
    )


if __name__ == "__main__":
    OUTPUT.write_text(render(SOURCE.read_bytes()), encoding="utf-8")
