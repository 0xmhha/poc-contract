#!/usr/bin/env bash
# Export the ABIs that indexer-go's DEX venues decode, so the indexer can pin them as fixtures.
#
# Usage:   ./script/export-venue-abi.sh            # writes abi/perpetual/*.json
#          ./script/export-venue-abi.sh --check    # exits 1 if committed ABIs are stale (for CI)
#
# Consumer: indexer-go pkg/features/dex (perp_orderbook venue). Changing an event signature or the
# getOrder() return layout in these contracts is a breaking change for the indexer.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="abi/perpetual"
CONTRACTS=(
  "src/perpetual/PerpetualEngine.sol:PerpetualEngine"
  "src/perpetual/core/OrderManager.sol:OrderManager"
)

CHECK=false
[[ "${1:-}" == "--check" ]] && CHECK=true

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for target in "${CONTRACTS[@]}"; do
  name="${target##*:}"
  forge inspect "$target" abi --json \
    | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), indent=2, sort_keys=True))' \
    > "$TMP_DIR/$name.json"
done

if $CHECK; then
  diff -r "$TMP_DIR" "$OUT_DIR" >/dev/null || { echo "abi/perpetual is stale; run ./script/export-venue-abi.sh" >&2; exit 1; }
  echo "abi/perpetual is up to date"
else
  mkdir -p "$OUT_DIR"
  cp "$TMP_DIR"/*.json "$OUT_DIR"/
  echo "Wrote $(ls "$OUT_DIR" | wc -l | tr -d ' ') ABI file(s) to $OUT_DIR"
fi
