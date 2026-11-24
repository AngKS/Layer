#!/bin/bash
# The gate for the flat model, which plan 6 deletes (its call 1): finds the flat model's names in Layer/, LayerTests/,
# LayerUITests/ and Tools/, in *.swift and *.sh files, leaving out .build/ and the app files the screen harness copies
# into Tools/*/Sources/*/App/. Prints each hit as file:line, then "flat model: N references in M files", with
# ", all allowed" when every one is.
#
# Tier 1 is every flat type and projection member. Without --strict, a tier-1 hit is allowed when its file is listed in
# one of the lanes' allowlists, scripts/flat-model-allowlist/{a,b,c}.txt: a path from the repository's root on each
# line, with anything after a # a note. A lane only ever takes lines out of its own list.
#
# --strict checks tier 2 too (ElementRef and TreeProjection, which plan 6's Task 11 renames or deletes), and allows
# nothing. After Task 11 it is the only mode.
#
# Exits 1 on any hit that isn't allowed, and 0 otherwise.
set -euo pipefail

cd "$(dirname "$0")/.."

strict=0
case "${1:-}" in
  --strict) strict=1 ;;
  "") ;;
  *) echo "usage: $0 [--strict]" >&2; exit 2 ;;
esac

tier1='\b(DesignElement|DesignScreen|FloatingElement|DesignContent|TreeLift|ElementConversion|pendingPointers|keepGroupsSound|keptTargets|SiblingLists|CodeOfElements)\b'
tier1+='|\bprojected(Update|Add|Remove|Move|Reorder|SetHost)\b'
tier1+='|PROJECTION:|Model/Projection'
tier1+='|\bselected(Element|Elements|Leaves|Screen)\b'
tier1+='|\bstore\.(screens|floating|resolve|element)\b'
tier1+='|LayerNode\(element:|ElementView\(element:|\bsetElements\(|\baddFloating\('
tier1+='|\bTreeProjection\.(lower|lowerHost|pose)\b'
tier1+='|\bplace\([^)]*centeredAt:|\bnewElement\('
tier2='\bElementRef\b|\bTreeProjection\b'

pattern="$tier1"
if [ "$strict" -eq 1 ]; then pattern="$tier1|$tier2"; fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# file:line for each line that holds a name, once however many it holds. grep finding nothing isn't a failure.
{ command grep -rnE --include='*.swift' --include='*.sh' --exclude-dir=.build "$pattern" \
    Layer LayerTests LayerUITests Tools || true; } \
  | command grep -vE '^Tools/[^/]+/Sources/[^/]+/App/' \
  | cut -d: -f1,2 >"$work/hits" || true

# The files the lanes allow, without notes or blank lines. None under --strict.
: >"$work/allowed"
if [ "$strict" -eq 0 ]; then
  for list in scripts/flat-model-allowlist/a.txt scripts/flat-model-allowlist/b.txt scripts/flat-model-allowlist/c.txt; do
    [ -f "$list" ] || continue
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$list" | command grep -v '^$' >>"$work/allowed" || true
  done
fi

awk -F: -v strict="$strict" -v allowedList="$work/allowed" '
  BEGIN { while ((getline path < allowedList) > 0) allowed[path] = 1 }
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
    count = 0
    for (file in files) count++
    line = sprintf("flat model: %d references in %d files", hits, count)
    if (!strict && !refused) line = line ", all allowed"
    print line
    if (refused) {
      refusedCount = 0
      for (file in refusedFiles) refusedCount++
      printf "not allowed: %d references in %d files\n", refused, refusedCount
    }
    status = 0
    if (strict && hits) status = 1
    if (!strict && refused) status = 1
    exit status
  }
' "$work/hits"
