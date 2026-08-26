//! Builtin dispatch and builtin implementations for the bytecode VM.

const Value = @import("runtime").value.Value;
const VM = @import("context.zig").VM;
const builtins_mod = @import("runtime").builtins;
const BuiltinId = builtins_mod.BuiltinId;
const shared = @import("builtins/shared.zig");
const strings = @import("builtins/strings.zig");
const errors = @import("builtins/errors.zig");
const string_context = @import("builtins/string_context.zig");
const attrsets = @import("builtins/attrsets.zig");
const serial = @import("builtins/serial.zig");
const fetch = @import("builtins/fetch.zig");
const flakes = @import("builtins/flakes.zig");
const purity = @import("builtins/purity.zig");
const source_store = @import("builtins/source_store.zig");
const derivation_builtins = @import("builtins/derivation.zig");
const predicates = @import("builtins/predicates.zig");
const arithmetic = @import("builtins/arithmetic.zig");
const lists = @import("builtins/lists.zig");
const paths = @import("builtins/paths.zig");
const io = @import("builtins/io.zig");
const hash = @import("builtins/hash.zig");
const vm_force = @import("force.zig");
const prof = @import("../probe.zig").prof;

pub const writeJsonValue = serial.writeJsonValue;
pub const writeLazyXmlValue = serial.writeLazyXmlValue;
pub const demandPathArg = io.demandPathArg;
pub const computeFlakeLock = flakes.computeFlakeLock;

pub fn applyBuiltin(self: *VM, builtin_id: u16, args: []const Value) !Value {
    const t = prof.startBuiltin(builtin_id);
    defer prof.end(.apply_builtin, t);
    const id: BuiltinId = @enumFromInt(builtin_id);
    const arity = builtins_mod.arity(id);
    if (args.len < arity) return shared.makeBuiltinClosure(self, builtin_id, args);
    if (args.len > arity) return error.TooManyArguments;

    // GC: args need no rooting here — every caller keeps them rooted
    // for the builtin's whole duration (doCall/doTailCall/callValue rootKeep
    // their arg; doCallN leaves args on the operand stack; evalThunkClosure's
    // builtin_closure is on the in-flight force chain). See `docs/gc.md`.
    return switch (id) {
        .toString => strings.builtinToString(self, args[0]),
        .isAttrs => predicates.builtinTypePredicate(self, args[0], .attrs),
        .isList => predicates.builtinTypePredicate(self, args[0], .list),
        .isString => predicates.builtinIsString(self, args[0]),
        .isInt => predicates.builtinTypePredicate(self, args[0], .int),
        .isBool => predicates.builtinIsBool(self, args[0]),
        .isNull => predicates.builtinTypePredicate(self, args[0], .null),
        .isFloat => predicates.builtinTypePredicate(self, args[0], .float),
        .isFunction => predicates.builtinIsFunction(self, args[0]),
        .isPath => predicates.builtinTypePredicate(self, args[0], .path),
        .length => lists.builtinLength(self, args[0]),
        .head => lists.builtinHead(self, args[0]),
        .tail => lists.builtinTail(self, args[0]),
        .attrNames => attrsets.builtinAttrNames(self, args[0]),
        .attrValues => attrsets.builtinAttrValues(self, args[0]),
        .typeOf => predicates.builtinTypeOf(self, args[0]),
        .concatLists => lists.builtinConcatLists(self, args[0]),
        .listToAttrs => lists.builtinListToAttrs(self, args[0]),
        .pathExists => io.builtinPathExists(self, args[0]),
        .readFile => io.builtinReadFile(self, args[0]),
        .import => io.builtinImport(self, args[0]),
        .readDir => io.builtinReadDir(self, args[0]),
        .readFileType => io.builtinReadFileType(self, args[0]),
        .findFile => io.builtinFindFile(self, args[0], args[1]),
        .hasAttr => attrsets.builtinHasAttr(self, args[0], args[1]),
        .getAttr => attrsets.builtinGetAttr(self, args[0], args[1]),
        .elemAt => lists.builtinElemAt(self, args[0], args[1]),
        .removeAttrs => attrsets.builtinRemoveAttrs(self, args[0], args[1]),
        .intersectAttrs => attrsets.builtinIntersectAttrs(self, args[0], args[1]),
        .elem => lists.builtinElem(self, args[0], args[1]),
        .seq => lists.builtinSeq(self, args[0], args[1]),
        .all => lists.builtinAll(self, args[0], args[1]),
        .any => lists.builtinAny(self, args[0], args[1]),
        .filter => lists.builtinFilter(self, args[0], args[1]),
        .map => lists.builtinMap(self, args[0], args[1]),
        .concatMap => lists.builtinConcatMap(self, args[0], args[1]),
        .mapAttrs => attrsets.builtinMapAttrs(self, args[0], args[1]),
        .genList => lists.builtinGenList(self, args[0], args[1]),
        .stringLength => strings.builtinStringLength(self, args[0]),
        .concatStringsSep => strings.builtinConcatStringsSep(self, args[0], args[1]),
        .foldlStrict => lists.builtinFoldlStrict(self, args[0], args[1], args[2]),
        .substring => strings.builtinSubstring(self, args[0], args[1], args[2]),
        .replaceStrings => strings.builtinReplaceStrings(self, args[0], args[1], args[2]),
        .deepSeq => lists.builtinDeepSeq(self, args[0], args[1]),
        .throw => errors.builtinThrow(self, args[0]),
        .abort => errors.builtinAbort(self, args[0]),
        .tryEval => errors.builtinTryEval(self, args[0]),
        .trace => errors.builtinTrace(self, args[0], args[1]),
        .derivation => derivation_builtins.builtinDerivation(self, args[0], .lazy),
        .derivationStrict => derivation_builtins.builtinDerivation(self, args[0], .strict),
        .storePath => paths.builtinStorePath(self, args[0]),
        .path => paths.builtinPath(self, args[0]),
        .sort => lists.builtinSort(self, args[0], args[1]),
        .partition => lists.builtinPartition(self, args[0], args[1]),
        .groupBy => lists.builtinGroupBy(self, args[0], args[1]),
        .genericClosure => lists.builtinGenericClosure(self, args[0]),
        .functionArgs => attrsets.builtinFunctionArgs(self, args[0]),
        .unsafeGetAttrPos => attrsets.builtinUnsafeGetAttrPos(self, args[0], args[1]),
        .add => arithmetic.builtinAdd(self, args[0], args[1]),
        .sub => arithmetic.builtinSub(self, args[0], args[1]),
        .mul => arithmetic.builtinMul(self, args[0], args[1]),
        .div => arithmetic.builtinDiv(self, args[0], args[1]),
        .lessThan => arithmetic.builtinLessThan(self, args[0], args[1]),
        .bitAnd => arithmetic.builtinBitAnd(self, args[0], args[1]),
        .bitOr => arithmetic.builtinBitOr(self, args[0], args[1]),
        .bitXor => arithmetic.builtinBitXor(self, args[0], args[1]),
        .floor => arithmetic.builtinFloor(self, args[0]),
        .ceil => arithmetic.builtinCeil(self, args[0]),
        .baseNameOf => paths.builtinBaseNameOf(self, args[0]),
        .dirOf => paths.builtinDirOf(self, args[0]),
        .catAttrs => attrsets.builtinCatAttrs(self, args[0], args[1]),
        .zipAttrsWith => attrsets.builtinZipAttrsWith(self, args[0], args[1]),
        .hashString => hash.builtinHashString(self, args[0], args[1]),
        .hashFile => hash.builtinHashFile(self, args[0], args[1]),
        .mapAttrValue => attrsets.builtinMapAttrValue(self, args[0], args[1], args[2]),
        .zipAttrsValue => attrsets.builtinZipAttrsValue(self, args[0], args[1], args[2]),
        .toJSON => serial.builtinToJSON(self, args[0]),
        .fromJSON => serial.builtinFromJSON(self, args[0]),
        .toXML => serial.builtinToXML(self, args[0]),
        .compareVersions => serial.builtinCompareVersions(self, args[0], args[1]),
        .splitVersion => serial.builtinSplitVersion(self, args[0]),
        .parseDrvName => serial.builtinParseDrvName(self, args[0]),
        .getEnv => source_store.builtinGetEnv(self, args[0]),
        .match => serial.builtinMatch(self, args[0], args[1]),
        .split => serial.builtinSplit(self, args[0], args[1]),
        .fromTOML => serial.builtinFromTOML(self, args[0]),
        .filterSource => source_store.builtinFilterSource(self, args[0], args[1]),
        .fetchGit => fetch.builtinFetchGit(self, args[0]),
        .fetchurl => fetch.builtinFetchurl(self, args[0]),
        .fetchTarball => fetch.builtinFetchTarball(self, args[0]),
        .fetchTree => flakes.builtinFetchTreeEntry(self, args[0]),
        .parseFlakeRef => flakes.builtinParseFlakeRefEntry(self, args[0]),
        .flakeRefToString => flakes.builtinFlakeRefToStringEntry(self, args[0]),
        .fetchMercurial => fetch.builtinFetchMercurial(self, args[0]),
        .getFlake => flakes.builtinGetFlakeEntry(self, args[0]),
        .scopedImport => io.builtinScopedImport(self, args[0], args[1]),
        .traceVerbose => errors.builtinTraceVerbose(self, args[0], args[1]),
        .warn => errors.builtinWarn(self, args[0], args[1]),
        .addErrorContext => errors.builtinAddErrorContext(self, args[0], args[1]),
        .unsafeDiscardStringContext => string_context.builtinUnsafeDiscardStringContext(self, args[0]),
        .unsafeDiscardOutputDependency => string_context.builtinUnsafeDiscardOutputDependency(self, args[0]),
        .addDrvOutputDependencies => string_context.builtinAddDrvOutputDependencies(self, args[0]),
        .appendContext => string_context.builtinAppendContext(self, args[0], args[1]),
        .break_ => errors.builtinBreak(self, args[0]),
        .getContext => string_context.builtinGetContext(self, args[0]),
        .hasContext => string_context.builtinHasContext(self, args[0]),
        .toPath => source_store.builtinToPath(self, args[0]),
        .toFile => source_store.builtinToFile(self, args[0], args[1]),
        .placeholder => paths.builtinPlaceholder(self, args[0]),
        .derivationLazyAttr => derivation_builtins.builtinDerivationLazyAttr(self, args[0], args[1]),
        .mapValue => lists.builtinMapValue(self, args[0], args[1]),
        .constantValue => args[0],
        .pure_guarded => purity.guardedPureValue(self, args[0]),
        .resolve_flake_node => flakes.resolveFlakeNode(self, args[0], args[1], args[2]),
        .compute_nar_hash => fetch.computeNarHash(self, args[0], args[1]),
        .shallow_rev_count => fetch.shallowRevCount(self, args[0]),
    };
}
