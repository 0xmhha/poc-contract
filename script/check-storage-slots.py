#!/usr/bin/env python3
"""Check hard-coded storage slot constants against the namespace they declare.

Upgradeable code here addresses storage through bytes32 constants (`*_SLOT`, `*_SEED`,
`*_LOCATION`) written as hex literals. A typo in a literal, or two modules picking the same
namespace, silently corrupts storage, and layout tools such as OpenZeppelin Upgrades do not
see slots used from assembly. This script makes the declaration checkable:

  // keccak256("kernel.hookGasLimit")                                   -> keccak256(id)
  // bytes32(uint256(keccak256('kernel.v3.hook')) - 1)                  -> keccak256(id) - 1
  // erc7201("example.main")                                            -> ERC-7201
  // keccak256(abi.encode(uint256(keccak256("x")) - 1)) & ~bytes32(uint256(0xff))  -> ERC-7201
  bytes32 private constant _HOOK_GAS_LIMIT_SLOT = 0x...;

For every such constant under src/ (vendored code excluded), the comment directly above must
name the formula and namespace id. The script recomputes the slot with `cast keccak` and fails
on a missing declaration, a mismatching literal, or a slot or namespace id used twice.

Usage: python3 script/check-storage-slots.py   (needs Foundry's `cast` on PATH)
"""

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
EXCLUDE = ("/vendor/",)

DECL = re.compile(
    r"bytes32\s+(?:(?:private|internal|public)\s+)?constant\s+(\w*(?:SLOT|SEED|LOCATION))\s*=\s*(0x[0-9a-fA-F_]+)\s*;"
)
ID = re.compile(r"""keccak256\(\s*(?:bytes\()?\s*["']([^"']+)["']|erc7201\(\s*["']([^"']+)["']""")


def keccak(data: str) -> int:
    out = subprocess.check_output(["cast", "keccak", data], text=True).strip()
    return int(out, 16)


def expected_slot(comment: str):
    """Return (formula, id, slot) for the formula a comment declares, or None."""
    m = ID.search(comment)
    if not m:
        return None
    ns = m.group(1) or m.group(2)
    if "erc7201(" in comment or "0xff" in comment:
        inner = keccak(ns) - 1
        return "erc7201", ns, keccak("0x" + inner.to_bytes(32, "big").hex()) & ~0xFF
    if re.search(r"\)\s*-\s*1", comment):
        return "keccak-1", ns, keccak(ns) - 1
    return "keccak", ns, keccak(ns)


def comment_above(lines, idx):
    """Join the contiguous // comment lines directly above line idx."""
    block = []
    i = idx - 1
    while i >= 0 and lines[i].strip().startswith("//"):
        block.insert(0, lines[i].strip())
        i -= 1
    return " ".join(block)


def main() -> int:
    errors, seen_slots, seen_ids, checked = [], {}, {}, 0
    for path in sorted(SRC.rglob("*.sol")):
        rel = str(path.relative_to(ROOT))
        if any(x in "/" + rel for x in EXCLUDE):
            continue
        text = path.read_text()
        lines = text.splitlines()
        for m in DECL.finditer(text):
            name, literal = m.group(1), int(m.group(2).replace("_", ""), 16)
            line_no = text.count("\n", 0, m.start())
            where = f"{rel}:{line_no + 1} {name}"
            exp = expected_slot(comment_above(lines, line_no))
            if exp is None:
                errors.append(f"{where}: no formula comment (e.g. // keccak256(\"namespace.id\")) directly above")
                continue
            formula, ns, slot = exp
            checked += 1
            if slot != literal:
                errors.append(f"{where}: literal does not match {formula}(\"{ns}\") = 0x{slot:064x}")
            if literal in seen_slots:
                errors.append(f"{where}: slot already used by {seen_slots[literal]}")
            if ns in seen_ids:
                errors.append(f"{where}: namespace \"{ns}\" already used by {seen_ids[ns]}")
            seen_slots.setdefault(literal, where)
            seen_ids.setdefault(ns, where)
            print(f"ok  {formula:9} {ns:40} {where}")

    for e in errors:
        print(f"ERROR {e}", file=sys.stderr)
    print(f"{checked} slot constants checked, {len(errors)} error(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
