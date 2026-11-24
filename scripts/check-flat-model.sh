#!/bin/bash
# The gate for the flat model, which plan 6 deletes (its call 1): finds the flat model's names in Layer/, LayerTests/,
# LayerUITests/ and Tools/, in *.swift and *.sh files, leaving out .build/ and the app files the screen harness copies
# into Tools/*/Sources/*/App/. Prints each hit as file:line, then "flat model: N references in M files", with
# ", all allowed" when every one is.
#
# Tier 1 is every flat type and projection member. Without --strict, a tier-1 hit is allowed when its file is listed in
# one of the lanes' allowlists, scripts/flat-model-allowlist/{a,b,c}.txt: a path from the repository's root on each
# line, with anything after a # a note. A lane only ever takes lines out of its own list. A line whose file has no
# tier-1 hit left is stale, and is reported: the lane that ported the file takes its line out.
#
# --strict checks tier 2 too (ElementRef and TreeProjection, which plan 6's Task 11 renames or deletes), and allows
# nothing. After Task 11 it is the only mode.
#
# Exits 1 on any hit that isn't allowed and, without --strict, on any stale line; 0 otherwise. Exits 2, saying why,
# when it can't search: a folder it searches is missing, or the search itself fails. A search that can't run never
# reads as a clean tree.
set -euo pipefail

cd "$(dirname "$0")/.."

strict=0
case "${1:-}" in
  --strict) strict=1 ;;
  "") ;;
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

# file:line for each line that matches `pattern`, once however many names it holds, into `out`. Finding nothing is
# grep's 1, and is fine; anything above that is a search that failed.
search() {
  local pattern="$1" out="$2" status=0
  command grep -rnE --include='*.swift' --include='*.sh' --exclude-dir=.build "$pattern" "${roots[@]}" \
    >"$work/raw" || status=$?
  [ "$status" -le 1 ] || fail "the search failed (grep exited $status)"
  status=0
  command grep -vE '^Tools/[^/]+/Sources/[^/]+/App/' "$work/raw" >"$work/kept" || status=$?
  [ "$status" -le 1 ] || fail "the search's results couldn't be read (grep exited $status)"
  cut -d: -f1,2 "$work/kept" >"$out"
}

search "$tier1" "$work/tier1"
if [ "$strict" -eq 1 ]; then
  search "$tier1|$tier2" "$work/hits"
else
  cp "$work/tier1" "$work/hits"
fi

# Each list's lines as list:line:path, without notes or blank lines. A missing list is an empty one.
: >"$work/entries"
for list in scripts/flat-model-allowlist/a.txt scripts/flat-model-allowlist/b.txt scripts/flat-model-allowlist/c.txt; do
  [ -f "$list" ] || continue
  awk -v list="$list" '{
    path = $0
    sub(/#.*/, "", path)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", path)
    if (path != "") print list ":" FNR ":" path
  }' "$list" >>"$work/entries"
done

awk -F: -v strict="$strict" -v entries="$work/entries" -v tierOne="$work/tier1" '
  BEGIN {
    while ((getline entry < entries) > 0) {
      split(entry, part, ":")
      count++
      where[count] = part[1] ":" part[2]
      listed[count] = part[3]
      if (!strict) allowed[part[3]] = 1
    }
    while ((getline hit < tierOne) > 0) {
      split(hit, part, ":")
      tierOneFiles[part[1]] = 1
    }
  }
  {
    hits++
    files[$1] = 1
    if (!strict && !($1 in allowed)) {
      refused++
      refusedFiles[$1] = 1
      print $1 ":" $2 "  not allowed"
    } else {
      print $1 ":" $2
    }
  }
  END {
    fileCount = 0
    for (file in files) fileCount++
    line = sprintf("flat model: %d references in %d files", hits, fileCount)
    if (!strict && !refused) line = line ", all allowed"
    print line
    if (refused) {
      refusedCount = 0
      for (file in refusedFiles) refusedCount++
      printf "not allowed: %d references in %d files\n", refused, refusedCount
    }
    for (i = 1; i <= count; i++) {
      if (!(listed[i] in tierOneFiles)) {
        stale++
        printf "stale: %s lists %s, which has no tier-1 hit\n", where[i], listed[i]
      }
    }
    status = 0
    if (strict && hits) status = 1
    if (!strict && (refused || stale)) status = 1
    exit status
  }
' "$work/hits"
