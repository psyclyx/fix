# Sort-bound: `builtins.sort` over the input shapes whose costs diverge most
# between sorting strategies. Random and reversed separate O(n log n) from
# O(n^2); presorted is the case a merge strategy can regress; the keyed and
# string lanes put real work in the comparator, which is where `lib.sortOn`
# and attribute-name sorting spend their time; `small` is constant factor
# rather than asymptotics.
let
  n = 100000;

  # Nix has no `%`, and integer division truncates toward zero.
  mod = a: b: a - (a / b) * b;

  # 7919 is coprime with 104729, so `scramble` is injective below 104729 and
  # the random lane sorts distinct keys with no ties.
  scramble = i: mod (i * 7919 + 13) 104729;

  lt = a: b: a < b;
  sum = builtins.foldl' (a: b: a + b) 0;
in {
  random = sum (builtins.sort lt (builtins.genList scramble n));
  reversed = sum (builtins.sort lt (builtins.genList (i: n - i) n));
  presorted = sum (builtins.sort lt (builtins.genList (i: i) n));

  byKey = builtins.length (builtins.sort (a: b: a.k < b.k) (builtins.genList (i: {
    k = scramble i;
    v = i;
  }) 30000));

  strings = builtins.length (builtins.sort lt (builtins.genList (i: builtins.toJSON (scramble i)) 30000));

  small = sum (builtins.genList (k: sum (builtins.sort lt (builtins.genList (i: mod (i * 7 + k) 11) 8))) 20000);
}
