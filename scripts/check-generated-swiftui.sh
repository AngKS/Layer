#!/bin/bash
# Proves the SwiftUI Layer generates compiles. Runs GeneratedCodeExportTests, which writes the
# code of the tree's designs (the fixtures and others built in code, free and laid-out screens,
# custom frames and tokens) for each layout, title and preview setting, together and screen by
# screen, into a temporary folder, then typechecks each folder's files with swiftc. Exits 0 only
# when every file typechecks, and prints how many did.
#
# LAYER_SIMULATOR and LAYER_DERIVED_DATA override the simulator and DerivedData folder.
set -euo pipefail

cd "$(dirname "$0")/.."
SIMULATOR="${LAYER_SIMULATOR:-Layer iPad Pro 11 (semantic-tree)}"
DERIVED_DATA="${LAYER_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Layer-semantic-tree}"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

TEST_RUNNER_LAYER_CODE_OUT="$OUT" xcodebuild test -project Layer.xcodeproj -scheme Layer -testPlan CI \
  -destination "platform=iOS Simulator,name=$SIMULATOR" \
  -derivedDataPath "$DERIVED_DATA" \
  -skipPackagePluginValidation -only-testing:LayerTests/GeneratedCodeExportTests >"$OUT/xcodebuild.log" 2>&1 \
  || { tail -40 "$OUT/xcodebuild.log"; echo "The export test failed" >&2; exit 1; }

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

# Each folder's files are typechecked together, as one target holds them; several folders at once.
folders=()
for folder in "$OUT"/*/; do
  [ -d "$folder" ] || continue
  compgen -G "$folder*.swift" >/dev/null || continue
  folders+=("${folder%/}")
done
if [ "${#folders[@]}" -eq 0 ]; then echo "No generated files were written" >&2; exit 1; fi

typecheck() {
  local folder="$1" sdk="$2"
  xcrun swiftc -typecheck -sdk "$sdk" -target arm64-apple-ios27.0-simulator "$folder"/*.swift \
    || { echo "Typecheck failed in $(basename "$folder")" >&2; return 1; }
}
export -f typecheck
failed=0
printf '%s\0' "${folders[@]}" | xargs -0 -n1 -P 6 -I{} bash -c 'typecheck "$1" "$2"' _ {} "$SDK" || failed=1

total=0
for folder in "${folders[@]}"; do
  count=$(ls "$folder"/*.swift | wc -l)
  total=$((total + count))
done

if [ "$total" -eq 0 ]; then echo "No generated files were written" >&2; exit 1; fi
if [ "$failed" -ne 0 ]; then exit 1; fi
echo "$total files typecheck"
