#!/usr/bin/env bash
# End-to-end checks for `fix flake` (metadata, show, check, lock, update).
#   test/e2e/flake.sh [FIX]     (default zig-out/bin/fix)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
e2e_init "$@"

FF="--extra-experimental-features flakes --impure"

sub=$(e2e_mktemp)
root=$(e2e_mktemp)
cat >"$sub/flake.nix" <<'EOF'
{ outputs = { self, ... }: { v = 1; }; }
EOF
cat >"$root/flake.nix" <<EOF
{
  description = "root flake";
  inputs.sub.url = "path:$sub";
  outputs = { self, sub, ... }: {
    packages.x86_64-linux.default = derivation { name = "d"; system = "x86_64-linux"; builder = "/bin/sh"; };
    packages.x86_64-linux.hello = derivation { name = "h"; system = "x86_64-linux"; builder = "/bin/sh"; };
    packages.x86_64-linux.broken = throw "boom";
    apps.x86_64-linux.default = { type = "app"; program = "/bin/true"; };
    devShells.x86_64-linux.default = derivation { name = "s"; system = "x86_64-linux"; builder = "/bin/sh"; };
  };
}
EOF

# --- metadata ---------------------------------------------------------------
out=$($FIX flake metadata $FF "$root" 2>&1)
t "metadata: description" "root flake" "$out"
t "metadata: input listed" "sub" "$out"
t "metadata: self filtered out" "└───sub" "$out"

# --- show -------------------------------------------------------------------
out=$($FIX flake show $FF "$root" 2>&1)
t "show: packages tree" "packages" "$out"
t "show: leaf label" "hello: package" "$out"
t "show: app leaf" "default: app" "$out"
t "show: devshell leaf" "development environment" "$out"

# --- check (the broken output must fail) ------------------------------------
out=$($FIX flake check $FF "$root" 2>&1)
code=$?
t "check: reports failure" "FAIL packages.x86_64-linux.broken" "$out"
if [[ $code -ne 0 ]]; then pass "check: nonzero exit on failure"; else fail "check: exit was 0"; fi

# --- lock / update operate on the cwd flake; positionals are input names ----
# Fresh two-input root so partial updates are observable.
a=$(e2e_mktemp)
b=$(e2e_mktemp)
r2=$(e2e_mktemp)
echo '{ outputs = i: { v = 1; }; }' >"$a/flake.nix"
echo '{ outputs = i: { v = 2; }; }' >"$b/flake.nix"
cat >"$r2/flake.nix" <<EOF
{ inputs.a.url = "path:$a"; inputs.b.url = "path:$b"; outputs = i: { x = 1; }; }
EOF
anode() { grep -A3 "\"$1\": {" "$r2/flake.lock" | grep -o '"narHash": *"[^"]*"' | head -1; }

out=$(cd "$r2" && $FIX flake lock $FF 2>&1)
t "lock: reports written" "wrote flake.lock" "$out"
if [[ -f "$r2/flake.lock" ]]; then pass "lock: flake.lock exists"; else fail "lock: no flake.lock"; fi
a0=$(anode a)
b0=$(anode b)

# Change input a, then update ONLY a: a re-pins, b stays.
echo '{ outputs = i: { v = 999; }; }' >"$a/flake.nix"
out=$(cd "$r2" && $FIX flake update a $FF 2>&1)
t "update a: reports updated" "updated flake.lock" "$out"
a1=$(anode a)
b1=$(anode b)
if [[ "$a0" != "$a1" ]]; then pass "update a: a re-pinned"; else fail "update a: a unchanged"; fi
if [[ "$b0" == "$b1" ]]; then pass "update a: b left frozen"; else fail "update a: b changed"; fi

# update (no args) re-pins everything.
echo '{ outputs = i: { v = 3; }; }' >"$b/flake.nix"
out=$(cd "$r2" && $FIX flake update $FF 2>&1)
b2=$(anode b)
if [[ "$b1" != "$b2" ]]; then pass "update (all): b re-pinned"; else fail "update (all): b unchanged"; fi

# lock completes a missing input without touching existing pins.
a2=$(anode a)
b3=$(anode b)
cat >"$r2/flake.nix" <<EOF
{ inputs.a.url = "path:$a"; inputs.b.url = "path:$b"; inputs.c.url = "path:$sub"; outputs = i: { x = 1; }; }
EOF
out=$(cd "$r2" && $FIX flake lock $FF 2>&1)
if grep -q '"c":' "$r2/flake.lock"; then pass "lock: added new input c"; else fail "lock: c not added"; fi
if [[ "$a2" == "$(anode a)" && "$b3" == "$(anode b)" ]]; then pass "lock: existing pins untouched"; else fail "lock: existing pins changed"; fi

# --- errors -----------------------------------------------------------------
out=$($FIX flake bogus 2>&1)
t "unknown subcommand" "unknown flake subcommand 'bogus'" "$out"

e2e_finish
