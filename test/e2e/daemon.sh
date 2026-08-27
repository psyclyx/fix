#!/usr/bin/env bash
# End-to-end checks against a real CppNix or Lix daemon.
# Set FIX_REQUIRE_DAEMON=1 in compatibility CI so connection failures cannot
# turn into skips; ordinary local runs remain useful without a running daemon.
#   test/e2e/daemon.sh [FIX]     (default zig-out/bin/fix)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
e2e_init "$@"

drv_expr='builtins.derivation {
  name = "fix-daemon-e2e";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = [ "-c" "printf daemon-compatible > \"$out\"" ];
}'

# This simultaneously probes the connection, exercises nix.conf comment
# parsing, and verifies that the user-level store setting reaches setup.
out=$(env NIX_CONFIG='store = daemon # use the local compatibility socket' \
    "$FIX" instantiate -E "$drv_expr" 2>&1)
code=$?
if ((code != 0)); then
    if [[ "${FIX_REQUIRE_DAEMON:-0}" == 1 ]]; then
        fail "daemon: required connection"
        echo "  got: $(printf '%q' "$out")" | head -c 2000
        echo
    else
        skip "daemon compatibility" "no reachable daemon"
    fi
    e2e_finish
fi
t "daemon: instantiate through commented store setting" "/nix/store/" "$out"

# Lix's `protocol=any` URI treats the path as a socket directory. fix selects
# the legacy socket within it, which also works against a CppNix daemon.
daemon_base="${NIX_STATE_DIR:-/nix/var/nix}/daemon-socket"
out=$("$FIX" instantiate --store "unix://${daemon_base}?protocol=any" -E "$drv_expr" 2>&1)
code=$?
if ((code == 0)); then
    pass "daemon: Lix protocol=any legacy fallback"
else
    fail "daemon: Lix protocol=any legacy fallback"
    echo "  got: $(printf '%q' "$out")" | head -c 2000
    echo
fi

xp_uri="unix://${daemon_base}?protocol=lix-xp-1"
out=$("$FIX" instantiate --store "$xp_uri" -E "$drv_expr" 2>&1)
if (($? != 0)) && [[ "$out" == *"only offers lix-xp-1"* ]]; then
    pass "daemon: XP-only endpoint fails without implementation delegation"
else
    fail "daemon: XP-only endpoint fails without implementation delegation"
    echo "  got: $(printf '%q' "$out")" | head -c 2000
    echo
fi

out=$("$FIX" instantiate --store auto -E "$drv_expr" 2>&1)
if (($? != 0)) && [[ "$out" == *"native local-store backend"* ]]; then
    pass "store auto: fails without implementation delegation"
else
    fail "store auto: fails without implementation delegation"
    echo "  got: $(printf '%q' "$out")" | head -c 2000
    echo
fi

custom_state=$(e2e_mktemp)
mkdir -p "$custom_state/daemon-socket"
ln -s "$daemon_base/socket" "$custom_state/daemon-socket/socket"
out=$(env NIX_STATE_DIR="$custom_state" "$FIX" instantiate -E "$drv_expr" 2>&1)
if (($? == 0)); then
    pass "daemon: NIX_STATE_DIR selects socket"
else
    fail "daemon: NIX_STATE_DIR selects socket"
    echo "  got: $(printf '%q' "$out")" | head -c 2000
    echo
fi

out=$("$FIX" build --no-out-link -E "$drv_expr" 2>&1)
code=$?
if ((code == 0)); then
    pass "daemon: realize derivation"
else
    fail "daemon: realize derivation"
    echo "  got: $(printf '%q' "$out")" | head -c 2000
    echo
fi
t "daemon: reports realized store path" "/nix/store/" "$out"

# readFile demands the path immediately. This catches the fresh-process case
# where toFile has a pending text recipe but the path does not exist yet.
out=$("$FIX" eval --raw --read-write-mode -E \
    'builtins.readFile (builtins.toFile "fix-daemon-e2e-text" "text-via-daemon")' 2>&1)
code=$?
if ((code == 0)); then
    pass "daemon: realize toFile before readFile"
else
    fail "daemon: realize toFile before readFile"
fi
t "daemon: read fresh text object" "text-via-daemon" "$out"

# `--read-write-mode` must REGISTER what it names, not just name it. Nothing
# demands a bare coercion's closure -- the CLI prints the value and exits -- so
# these regressed to computing the path and dropping the recipe on the floor.
# Fresh bytes per run keep the "not registered yet" half honest.
rw_dir=$(e2e_mktemp)
rw_stamp="rw-$$-$(date +%s%N)"
mkdir -p "$rw_dir/tree" "$rw_dir/filtered"
printf 'registered-%s' "$rw_stamp" >"$rw_dir/tree/inner.txt"
# Its own bytes: an accept-all filterSource of $rw_dir/tree would land on the
# store path the toJSON case just registered, silently voiding that check.
printf 'filtered-%s' "$rw_stamp" >"$rw_dir/filtered/inner.txt"
printf 'coerced-%s' "$rw_stamp" >"$rw_dir/coerce.txt"
printf 'flat-%s' "$rw_stamp" >"$rw_dir/flat.txt"

# --raw of a toJSON result is a JSON string; strip the quotes so every case
# yields a bare store path.
rw_path() { # rw_path <expr> <extra fix args...>
    local expr="$1" out
    shift
    out=$("$FIX" eval --raw "$@" -E "$expr" 2>/dev/null)
    printf '%s' "${out%\"}" | sed -e 's/^"//'
}
# Registration, not mere presence: a `.check`-style verify proves the path is in
# the daemon's database. Fall back to existence where nix-store is absent.
rw_verify() { # rw_verify <store path>
    if command -v nix-store >/dev/null 2>&1; then
        nix-store --verify-path "$1" >/dev/null 2>&1
    else
        test -e "$1"
    fi
}
rw_registered() { # rw_registered <name> <expr>
    local name="$1" expr="$2" quiet path
    quiet=$(rw_path "$expr")
    ok_if "$name: plain eval leaves it unregistered" test ! -e "$quiet"
    path=$(rw_path "$expr" --read-write-mode)
    t "$name: same store path under --read-write-mode" "$quiet" "$path"
    ok_if "$name: --read-write-mode registers it" rw_verify "$path"
}

rw_registered "daemon: interpolated path" "\"\${$rw_dir/coerce.txt}\""
rw_registered "daemon: toJSON path" "builtins.toJSON $rw_dir/tree"
rw_registered "daemon: builtins.path" \
    "builtins.path { path = $rw_dir/tree; name = \"fix-daemon-e2e-rw-$rw_stamp\"; }"
rw_registered "daemon: flat builtins.path" \
    "builtins.path { path = $rw_dir/flat.txt; recursive = false; }"
rw_registered "daemon: filterSource" "builtins.filterSource (p: t: true) $rw_dir/filtered"
rw_registered "daemon: toFile" "builtins.toFile \"fix-daemon-e2e-tofile\" \"body-$rw_stamp\""

# The subpath analogue: reading `src + "/inner.txt"` out of a fresh ingested
# tree materializes the tree's store root.
subread_dir=$(e2e_mktemp)
mkdir -p "$subread_dir/tree"
printf 'sub-read-through-root' >"$subread_dir/tree/inner.txt"
out=$("$FIX" eval --raw --read-write-mode -E "
  let src = builtins.path { path = $subread_dir/tree; name = \"fix-daemon-e2e-subread\"; };
  in builtins.readFile (src + \"/inner.txt\")" 2>&1)
t "daemon: readFile of a fresh tree subpath materializes the root" "sub-read-through-root" "$out"
mkdir -p "$subread_dir/tree2/sub"
printf 'nested-leaf' >"$subread_dir/tree2/sub/leaf.txt"
out=$("$FIX" eval --json --read-write-mode -E "
  let src = builtins.path { path = $subread_dir/tree2; name = \"fix-daemon-e2e-subread\"; };
  in builtins.attrNames (builtins.readDir (src + \"/sub\"))" 2>&1)
t "daemon: readDir of a fresh tree subpath materializes the root" "leaf.txt" "$out"

# A `path:` fetch of an existing store path returns it verbatim, as Nix does.
adopt_dir=$(e2e_mktemp)
mkdir -p "$adopt_dir/tree"
printf 'adopt-me' >"$adopt_dir/tree/inner.txt"
out=$("$FIX" eval --raw --read-write-mode --impure \
    --extra-experimental-features fetch-tree -E "
  let a = toString (builtins.path { path = $adopt_dir/tree; name = \"fix-daemon-e2e-adopt\"; });
  in builtins.seq (builtins.pathExists a)
    (if (builtins.fetchTree { type = \"path\"; path = a; }).outPath == a
     then \"adopted-verbatim\" else \"re-ingested\")" 2>&1)
t "daemon: fetchTree adopts an existing store path verbatim" "adopted-verbatim" "$out"

# AddIndirectRoot's dummy result must be consumed so the connection stays
# usable for the next operation.
root_dir=$(e2e_mktemp)
drv2_expr='builtins.derivation {
  name = "fix-daemon-e2e-2";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = [ "-c" "printf second > \"$out\"" ];
}'
out=$("$FIX" instantiate --add-root "$root_dir/root" --indirect -E "$drv_expr" -E "$drv2_expr" 2>&1)
t "daemon: connection survives an indirect root registration" "fix-daemon-e2e-2.drv" "$out"
t_absent "daemon: no stray result after indirect root" "unknown stderr message" "$out"

# A PATH VALUE at a store path copies under its full basename on string
# coercion, as Nix's copyPathToStore does; only string-shaped store paths
# pass through.
srccopy_dir=$(e2e_mktemp)
mkdir -p "$srccopy_dir/tree"
printf 'copy-me' >"$srccopy_dir/tree/inner.txt"
out=$("$FIX" eval --raw --read-write-mode --impure -E "
  let sp = builtins.unsafeDiscardStringContext (toString (builtins.path { path = $srccopy_dir/tree; name = \"fix-daemon-e2e-srccopy\"; }));
      copied = \"\" + (/. + sp);
      bn = baseNameOf sp;
      bc = baseNameOf copied;
      lb = builtins.stringLength bn;
      lc = builtins.stringLength bc;
  in builtins.seq (builtins.pathExists sp)
     (if copied == sp then \"passed-through\"
      else if lc > lb && builtins.substring (lc - lb) lb bc == bn then \"copied-under-full-basename\"
      else \"copied-other-name\")" 2>&1)
t "daemon: a store-path path value copies under its full basename" "copied-under-full-basename" "$out"

# An absolute store URI is a Nix/Lix chroot store root. It must not silently
# delegate to an installed implementation while the native backend is pending.
local_root=$(e2e_mktemp)
out=$("$FIX" instantiate --store "$local_root" -E "$drv_expr" 2>&1)
if (($? != 0)) && [[ "$out" == *"native local-store backend"* ]]; then
    pass "local store: fails without implementation delegation"
else
    fail "local store: fails without implementation delegation"
    echo "  got: $(printf '%q' "$out")" | head -c 2000
    echo
fi

e2e_finish
