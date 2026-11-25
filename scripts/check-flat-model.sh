#!/bin/bash
# The gate for the flat model, which plan 6 deleted (its call 1, Task 11): finds the flat model's names in Layer/,
# LayerTests/, LayerUITests/ and Tools/, in *.swift and *.sh files, leaving out .build/ and the app files the screen
# harness copies into Tools/*/Sources/*/App/. Prints each hit as file:line, then "flat model: N references in M files".
#
# Tier 1 is every flat type and projection member, tier 2 the names Task 11 renamed or deleted last (ElementRef,
# TreeProjection). Nothing is allowed: the model is the tree alone. `--strict`, the mode the lanes ran at the end of
# Tasks 11 and 12, is accepted and is the same check.
#
# Exits 1 on any hit, 0 otherwise. Exits 2, saying why, when it can't search: a folder it searches is missing, or the
# search itself fails. A search that can't run never reads as a clean tree.
set -euo pipefail

cd "$(dirname "$0")/.."

case "${1:-}" in
  --strict | "") ;;
  *) echo "usage: $0 [--strict]" >&2; exit 2 ;;
esac

fail() {
  echo "check-flat-model: $*" >&2
  exit 2
}

roots=(Layer LayerTests LayerUITests Tools)
for root in "${roots[@]}"; do
  [ -d "$root" ] || fail "$(pwd)/$root is missing, so it can't be searched"
done

tier1='\b(DesignElement|DesignScreen|FloatingElement|DesignContent|TreeLift|ElementConversion|pendingPointers|keepGroupsSound|keptTargets|SiblingLists|CodeOfElements)\b'
tier1+='|\bprojected(Update|Add|Remove|Move|Reorder|SetHost)\b'
tier1+='|PROJECTION:|Model/Projection'
tier1+='|\bselected(Element|Elements|Leaves|Screen)\b'
tier1+='|\bstore\.(screens|floating|resolve|element)\b'
tier1+='|LayerNode\(element:|ElementView\(element:|\bsetElements\(|\baddFloating\('
tier1+='|\bTreeProjection\.(lower|lowerHost|pose)\b'
tier1+='|\bplace\([^)]*centeredAt:|\bnewElement\('
# The flat store's and content's screen lookups (screen(_:), screen(at:), screen(under:)), called or passed as a
# function; the tree's are treeScreen and screenID(under:).
tier1+='|\b(store|content)\??\.screen\b'
# The flat screen update, the store's and the content's; the tree's is updateTreeScreen.
tier1+='|\bupdateScreen\('
# Plan 5's sketch wrapper, addElement(_:from:to:); voice's addElement tool takes no sketch.
tier1+='|\baddElement\([^)]*from:'
# The flat update(_ ref:), and the content's own update of an element, where the text shows it: a ref passed by its
# name or built in place, or a closure setting a field only the flat element has. A ref under another name, setting a
# frame, lock or hide, reads the same as the tree's update(_ id:), which takes a node's id, and isn't told apart here.
tier1+='|\bupdate\((ref|[A-Za-z_][A-Za-z0-9_.]*\.ref|refs?\[[^]]*\])\)|\bupdate\(\.init\(host:'
tier1+='|\bupdate\([^)]*\)[[:space:]]*\{[[:space:]]*\$0\.(text|tint|symbol|shape|imageID|fontSize|fontWeight|textColor|cornerRadius|opacity|textAlignment|borderColor|borderWidth|hasShadow|isOn|value|buttonLook|ink|group|setRotation)\b'
tier2='\bElementRef\b|\bTreeProjection\b'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# file:line for each line that matches, once however many names it holds. Finding nothing is grep's 1, and is fine;
# anything above that is a search that failed.
status=0
command grep -rnE --include='*.swift' --include='*.sh' --exclude-dir=.build "$tier1|$tier2" "${roots[@]}" \
  >"$work/raw" || status=$?
[ "$status" -le 1 ] || fail "the search failed (grep exited $status)"
status=0
command grep -vE '^Tools/[^/]+/Sources/[^/]+/App/' "$work/raw" >"$work/kept" || status=$?
[ "$status" -le 1 ] || fail "the search's results couldn't be read (grep exited $status)"

awk -F: '
  { hits++; files[$1] = 1; print $1 ":" $2 }
  END {
    fileCount = 0
    for (file in files) fileCount++
    printf "flat model: %d references in %d files\n", hits, fileCount
    exit hits ? 1 : 0
  }
' "$work/kept"
