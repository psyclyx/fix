#!/usr/bin/env bash
# End-to-end checks for the CLI entry/printing layer: how arguments are
# consumed and how the chosen output format renders a value. These live here
# rather than in unit tests because the defects they guard against were only
# visible in the composition — argv parsing feeding the evaluator feeding a
# writer — and each one produced plausible-looking output rather than an error.
#   test/e2e/cli.sh [FIX]     (default zig-out/bin/fix)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
e2e_init "$@"

# --- --color: attached and separated WHEN spellings agree -----------------
# `--color never` used to leave the flag at its bare-form value (always) and
# hand `never` to the source list as a file, so the command both errored and
# emitted escapes.
for form in "--color=never" "--color never"; do
    # shellcheck disable=SC2086 # deliberate word splitting of the flag form
    out=$("$FIX" eval $form -E '1 + 1' 2>&1)
    t_absent "$form leaves output unstyled" $'\033' "$out"
    t "$form evaluates" "2" "$out"
    t_absent "$form does not consume WHEN as a source" "reading input" "$out"
done

for form in "--color=always" "--color always"; do
    # shellcheck disable=SC2086 # deliberate word splitting of the flag form
    out=$("$FIX" eval $form -E '1 + 1' 2>/dev/null)
    t "$form styles output" $'\033' "$out"
done

out=$("$FIX" eval --color auto -E '1 + 1' 2>&1)
t_absent "--color auto is unstyled off a tty" $'\033' "$out"
out=$("$FIX" eval -E '1 + 1' 2>&1)
t_absent "no --color is unstyled off a tty" $'\033' "$out"

# A trailing `--color` keeps the bare-flag meaning; a non-WHEN token after it
# is still a source, so the lookahead cannot swallow a positional.
out=$("$FIX" eval -E '1 + 1' --color 2>/dev/null)
t "trailing --color means always" $'\033' "$out"
work="$(e2e_mktemp)"
echo '40 + 2' >"$work/source.nix"
out=$("$FIX" eval --color "$work/source.nix" 2>&1)
t "--color does not swallow a following path" "42" "$out"

"$FIX" eval --color never -E '1 + 1' >/dev/null 2>&1
ok_if "--color never exits 0" test "$?" = 0

# --- -E path literals resolve against the working directory ---------------
# `--expr` has no source file, so its base directory is the cwd (as in Nix).
# Unresolved literals silently reached readFile, coercion and comparison.
paths="$(e2e_mktemp)"
mkdir -p "$paths/sub"
echo 'hi' >"$paths/sub/foo.txt"
echo './neighbour.nix' >"$paths/rel.nix"

entry="$PWD"
cd "$paths/sub" || exit 2
t "-E resolves ./x against the cwd" "$paths/sub/foo.txt" "$("$FIX" eval -E './foo.txt')"
t "-E resolves ./." "$paths/sub" "$("$FIX" eval -E './.')"
t "-E resolves ../x" "$paths/x" "$("$FIX" eval -E '../x')"
t "-E leaves absolute paths alone" "/tmp/foo.txt" "$("$FIX" eval -E '/tmp/foo.txt')"
t "-E resolves a path inside interpolation" "-foo.txt" "$("$FIX" eval -E '"${./foo.txt}"')"
t "-E resolves a path reaching readFile" '"hi\n"' "$("$FIX" eval -E 'builtins.readFile ./foo.txt')"
t "-E resolves nested path literals" "$paths/sub/foo.txt" "$("$FIX" eval -E '[ ./foo.txt ]')"
# A FILE input resolves against its own directory, not the cwd -- `rel.nix`
# sits one level up, so a cwd-based base would give the wrong answer here.
t "FILE input still resolves against the file" "$paths/neighbour.nix" "$("$FIX" eval ../rel.nix)"
cd "$entry" || exit 2

# --- --json copies path values to the store -------------------------------
# The `--json` writer used toString semantics for paths, so it printed the
# source path where every other coercion (and Nix) yields the store path. No
# error, just a different string -- invisible in a pipeline.
json="$(e2e_mktemp)"
# The store path is content-addressed, so unique bytes keep the
# "not registered yet" check honest across runs.
echo "hello from $json" >"$json/README.md"

# The writer and `builtins.toJSON` are the same serializer, so a path renders
# identically through both. That pins the store hash without restating it.
want="$("$FIX" eval --raw -E "builtins.toJSON $json/README.md")"
t "--json path is a store path" "/nix/store/" "$want"
t "--json path keeps the source basename" "-README.md" "$want"
t "--json agrees with builtins.toJSON on a path" "$want" "$("$FIX" eval --json -E "$json/README.md")"
t "--json copies a path nested in a list" "$want" "$("$FIX" eval --json -E "[ $json/README.md ]")"
t "--json copies a path nested in an attrset" "$want" "$("$FIX" eval --json -E "{ a = { b = $json/README.md; }; }")"

# Non-path values are untouched by the coercion.
t "--json string" '"text"' "$("$FIX" eval --json -E '"text"')"
t "--json int" '42' "$("$FIX" eval --json -E '42')"
t "--json list" '[1,2,3]' "$("$FIX" eval --json -E '[ 1 2 3 ]')"
t "--json attrset" '{"a":1,"b":"two"}' "$("$FIX" eval --json -E '{ a = 1; b = "two"; }')"

# The coercion is a pure hash of the source, so plain `--json` renders the
# store path without writing anything -- `--read-write-mode` stays the only
# switch that may register it, exactly as in nix-instantiate.
store_path="$(sed -e 's/^"//' -e 's/"$//' <<<"$("$FIX" eval --json -E "$json/README.md")")"
ok_if "--json alone does not write to the store" test ! -e "$store_path"
t "--json --read-write-mode renders the same store path" "$want" \
    "$("$FIX" eval --json --read-write-mode -E "$json/README.md")"

e2e_finish
