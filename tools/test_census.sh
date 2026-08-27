#!/usr/bin/env bash
# Fail when a source file's `test` blocks are never collected by any suite.
#
# `zig test` only runs tests from files the compiler actually analyses, and
# analysis follows ordinary declaration references — so whether a file's tests
# run cannot be decided by reading imports. src/cli/source_render.zig was
# imported, compiled, and shipped for months with all three of its tests
# uncollected; the suite stayed green the whole time, because a test that does
# not exist cannot fail. Nothing short of running the suites detects this.
#
# So run them and count. The test runner names every test after the file that
# declares it, which is enough to recover the set of files that contributed
# tests; anything holding a `test` block and missing from that set is dead
# weight. The totals are compared too, since a file name can be ambiguous
# across domains while a count cannot.
#
# Not a `zig build` step on purpose: it drives `zig build test` itself, and a
# build step that re-enters the build is a trap. Run it directly, or from CI
# after the suites (the run steps are cached, so it costs nothing twice).
set -euo pipefail

repo=$(cd "${1:-.}" && pwd)
log=$(mktemp)
trap 'rm -f "$log"' EXIT

cd "$repo"
if [[ -n ${2:-} ]]; then
  cp "$2" "$log"
elif ! zig build test >"$log" 2>&1; then
  cat "$log" >&2
  echo "test-census: the suite failed; the census needs a green run" >&2
  exit 1
fi

# `12/540 repl.vm.root.test.source snippets honor their container width...OK`
# The prefix before `.test` is the declaring file's path below its module root,
# with '/' written as '.'. The module root itself is not in the name, so match
# the tail of the path and accept every source file that could have produced it
# — over-accepting here can only be corrected by the total below.
sources=$(rg --files --glob '*.zig' src | sort)
declare -A collected=()
while IFS= read -r prefix; do
  while IFS= read -r candidate; do
    collected[$candidate]=1
  done < <(grep -F -- "/${prefix//./\/}.zig" <<<"$sources")
done < <(rg --only-matching --replace '$1' '^[0-9]+/[0-9]+ (.*?)\.test(_[0-9]+)?[.(]' "$log" | sort -u)

failed=0
while IFS= read -r file; do
  [[ -n ${collected[$file]:-} ]] && continue
  echo "test-census: no suite collects the tests in $file" >&2
  failed=1
done < <(rg --files-with-matches --glob '*.zig' '^test\b' src | sort)

# Sum of each suite's denominator against the source inventory. src/<domain>
# partitions cleanly across the test binaries, so every `test` block in the
# tree must show up in exactly one suite's total.
ran=0
while IFS= read -r count; do ran=$((ran + count)); done < <(
  rg --only-matching --replace '$1' '^1/([0-9]+) [^ ]*\.test' "$log"
)
declared=0
while IFS= read -r count; do declared=$((declared + count)); done < <(
  rg --count-matches --no-filename --glob '*.zig' '^test\b' src
)
if ((ran != declared)); then
  echo "test-census: suites ran $ran tests; src declares $declared test blocks" >&2
  failed=1
fi

exit "$failed"
