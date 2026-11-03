#!/bin/sh
# Model-check TarshareStore, then check that each seeded protocol bug is caught.
# Usage: TLA2TOOLS=/path/to/tla2tools.jar sh design/spec/check.sh
# Needs Java and perl. tla2tools.jar: https://github.com/tlaplus/tlaplus/releases
set -eu
jar=${TLA2TOOLS:?set TLA2TOOLS to tla2tools.jar}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

tlc() {
  (cd "$1" && java -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers auto \
    -deadlock -metadir "$(mktemp -d "$work/meta.XXXXXX")" TarshareStore.tla 2>&1) |
    grep -E "No error has been found|is violated|was violated|^[0-9]+ states generated" |
    sed -n "1,2p"
}

# mutant NAME CFG-EDIT PERL-SUBSTITUTION: copy the spec, apply one bug, run TLC.
mutant() {
  dir="$work/$1"
  mkdir -p "$dir"
  cp "$here/TarshareStore.tla" "$here/TarshareStore.cfg" "$dir/"
  perl -0pi -e "$2" "$dir/TarshareStore.cfg"
  perl -0pi -e "$3" "$dir/TarshareStore.tla"
  if cmp -s "$here/TarshareStore.tla" "$dir/TarshareStore.tla"; then
    echo "[$1] mutation did not apply"; exit 1
  fi
  tlc "$dir" | sed "s/^/[$1] /"
}

echo "[model]"; tlc "$here"

# A hit that does not pin: collection can remove what the client is fetching.
mutant hit-without-pin '' \
  's/THEN \/\\ pins'"'"' = pins \\cup \{<<c, k>>\}/THEN \/\\ UNCHANGED pins/'
# Publication that overwrites: consumers of one key disagree.
mutant publish-overwrites '' \
  's/winner == IF actions\[k\] = None THEN result\[c\] ELSE actions\[k\]/winner == result[c]/'
# Publication without the committed-object check: an action points at nothing.
mutant publish-unchecked '' \
  's/IF result\[c\] \\notin committed/IF FALSE/'
# A crashed client keeps its lease: waiters never finish (liveness).
mutant crash-keeps-lease 's/  LeaseOnLiveConnection\n//' \
  's/(Crash\(c\) ==\n.*?\n.*?\n.*?\n)  \/\\ lease'"'"' = DropLeasesOf\(\{c\}\)\n  \/\\ drops'"'"' = DroppedCount\(\{c\}\)\n/$1/s; s/(computes, blips, gcs>>\n\n\\\* The connection drops)/computes, blips, gcs, lease, drops>>\n\n\\* The connection drops/'
