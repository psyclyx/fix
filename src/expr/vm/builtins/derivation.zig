//! The `derivation`/`derivationStrict` builtins: normalize the input attrs
//! into a Drv, compute its store paths, and build the lazy or strict
//! derivation value (including structured-attrs JSON and input drv/src
//! collection).
//! Fans per-attr forcing out to helper fibers and caches lazy-derivation
//! values keyed by attrs id + heap GC token (guards against id reuse).

const std = @import("std");
const observ = @import("base").observ;
const VM = @import("../context.zig").VM;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const derivation = @import("store").derivation;
const source_paths = @import("store").realization.source_path;
const attrsets = @import("attrsets.zig");
const serial = @import("serial.zig");
const shared = @import("shared.zig");
const strings = @import("strings.zig");
const string_context = @import("string_context.zig");
const vm_force = @import("../force.zig");
const vm_strings = @import("../strings.zig");
const vm_equality = @import("../equality.zig");
const vm_closures = @import("../closures.zig");
const vm_trace = @import("../trace.zig");
const prof = @import("../../probe.zig").prof;

const compute_derivation_observation: observ.SpanSpec = .{
    .category = "eval",
    .name = "derivation",
    .begin_verb = "computing derivation",
    .finish_verb = "computed derivation",
    .begin_level = 3,
    .finish_level = 2,
};

const allOutputsContextValue = string_context.allOutputsContextValue;
const appendContextEntry = string_context.appendContextEntry;
const coerceDerivationStringValue = strings.coerceDerivationStringValue;
const contextEntriesForValue = string_context.contextEntriesForValue;
const makeBuiltinThunk = shared.makeBuiltinThunk;
const jsonAttrsStringValue = serial.jsonAttrsStringValue;
const isPlainString = strings.isPlainString;
const isStringLike = strings.isStringLike;
const sourcePathStringValue = strings.sourcePathStringValue;
const stringTextInternId = strings.stringTextInternId;
const sortedAttrEntries = attrsets.sortedAttrEntries;

const SeenJsonObject = shared.SeenJsonObject;

pub const DerivationMode = enum { lazy, strict };

pub fn builtinDerivation(self: *VM, arg: Value, mode: DerivationMode) !Value {
    const attrs = try vm_force.forceValue(self, arg);
    if (!attrs.isAttrs()) return error.TypeError;

    if (mode == .lazy) return buildLazyDerivationValue(self, attrs.asObjectId());
    return buildForcedDerivationValue(self, attrs.asObjectId(), .strict);
}

/// Internal thunk-name prefix: `<prefix><output>` requests the outPath of
/// one named output (used by lazy per-output values, see
/// `buildLazyOutputValue`). `\x00` keeps it out of the user-visible
/// attr namespace.
const lazy_output_path_prefix = "\x00derivationOutputPath:";

pub fn builtinDerivationLazyAttr(self: *VM, attrs_arg: Value, name_arg: Value) !Value {
    const attrs = try vm_force.forceValue(self, attrs_arg);
    const name = try vm_force.forceValue(self, name_arg);
    if (!attrs.isAttrs() or !isPlainString(name)) return error.TypeError;

    const name_id = try strings.stringNameId(self, name);
    const attrs_id = attrs.asObjectId();
    const name_text = self.intern.get(name_id);

    if (std.mem.startsWith(u8, name_text, lazy_output_path_prefix)) {
        const output_id = try self.intern.intern(name_text[lazy_output_path_prefix.len..]);
        const forced = try forcedDerivationValueCached(self, attrs_id);
        const output_value = try self.heap.getAttrValue(forced.asObjectId(), output_id);
        if (!output_value.isAttrs()) return error.InvalidDerivationOutput;
        return self.heap.getAttrValue(output_value.asObjectId(), try self.intern.intern("outPath"));
    }

    // Selecting a named output (`drv.out`, `drv.dev`, …) must NOT compute
    // the derivation: in Nix's corelib `derivation`, each output value is an
    // ordinary attrset whose outPath/drvPath alone defer to derivationStrict.
    // (Real-world dependence: lib.extendDerivation inherits type/outputName
    // through `drv.${outputName}`, so an eager compute here would make a
    // mere `.type` check evaluate the full env — observably strict when an
    // env attr throws, e.g. python packages disabled for the interpreter.)
    {
        const output_names = try derivationOutputNames(self, attrs_id);
        defer self.allocator.free(output_names.names);
        for (output_names.names) |output| {
            if (output == name_id) return buildLazyOutputValue(self, attrs_id, name_id, output_names);
        }
    }

    const value = try forcedDerivationValueCached(self, attrs_id);
    return self.heap.getAttrValue(value.asObjectId(), name_id);
}

/// Force-and-cache the fully-computed derivation value for `attrs_id`. The
/// naïve path rebuilt the whole derivation per per-attr access (drvPath,
/// outPath, ...) — `buildForcedDerivationValue` is the bulk of
/// `derivationLazyAttr`'s wall time on workloads like the NixOS toplevel
/// where one derivation is touched for several of its lazy attrs.
fn forcedDerivationValueCached(self: *VM, attrs_id: ObjectId) !Value {
    const cached_bits = self.realization.lookupLazyDerivation(attrs_id, self.heap.token);
    if (cached_bits) |bits| return .{ .bits = bits };
    const built = try buildForcedDerivationValue(self, attrs_id, .lazy);
    // Best-effort cache; if the put fails (OOM) we still
    // proceed — correctness doesn't depend on caching. Token-guarded so a
    // GC that reuses `attrs_id` for a different attrs can't hit a stale entry.
    self.realization.cacheLazyDerivation(attrs_id, self.heap.token, built.bits) catch {};
    return built;
}

fn buildLazyDerivationValue(self: *VM, attrs_id: ObjectId) !Value {
    const output_names = try derivationOutputNames(self, attrs_id);
    defer self.allocator.free(output_names.names);
    return buildLazyValueForOutput(self, attrs_id, output_names.names[0], output_names, false);
}

/// Lazy per-output value (`drv.out`, `drv.dev`, …): the root lazy shape with
/// `outputName` fixed to the selected output and `outPath` resolving to that
/// output's path. Selecting an output stays free of derivation computation.
fn buildLazyOutputValue(self: *VM, attrs_id: ObjectId, output: InternId, output_names: DerivationOutputNames) !Value {
    return buildLazyValueForOutput(self, attrs_id, output, output_names, true);
}

fn buildLazyValueForOutput(
    self: *VM,
    attrs_id: ObjectId,
    selected: InternId,
    output_names: DerivationOutputNames,
    selected_out_path: bool,
) !Value {
    const outputs = try self.allocator.alloc(derivation.ValueOutput, output_names.names.len);
    defer self.allocator.free(outputs);
    for (output_names.names, outputs) |output_name, *output| {
        output.* = .{ .name = output_name, .out_path = output_name };
    }

    const original_attrs = try self.heap.materializeAttrs(attrs_id);
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);

    for (original_attrs.names, original_attrs.values) |entry_name, entry_value| {
        if (derivation.isSyntheticName(self.intern, self.intern.get(entry_name), outputs)) continue;
        try entries.append(self.allocator, .{ .name = entry_name, .value = entry_value });
    }

    try entries.append(self.allocator, .{
        .name = try self.intern.intern("type"),
        .value = Value.string(try self.intern.intern("derivation")),
    });
    try entries.append(self.allocator, .{
        .name = try self.intern.intern("outputName"),
        .value = Value.string(selected),
    });
    if (output_names.explicit) {
        try entries.append(self.allocator, .{
            .name = try self.intern.intern("outputs"),
            .value = Value.list(try lazyOutputNamesList(self, output_names.names)),
        });
    }
    try entries.append(self.allocator, .{
        .name = try self.intern.intern("drvAttrs"),
        .value = Value.attrs(try self.heap.addAttrsView(original_attrs)),
    });

    try appendLazyDerivationAttr(self, &entries, attrs_id, "drvPath");
    if (selected_out_path) {
        // Non-default output: `outPath` must resolve to the SELECTED output's
        // path. Route through the internal `\x00`-prefixed thunk name.
        const mangled = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{
            lazy_output_path_prefix, self.intern.get(selected),
        });
        defer self.allocator.free(mangled);
        const outpath_id = try self.intern.intern("outPath");
        const args = [_]Value{ Value.attrs(attrs_id), Value.string(try self.intern.intern(mangled)) };
        try entries.append(self.allocator, .{
            .name = outpath_id,
            .value = try makeBuiltinThunk(self, .derivationLazyAttr, &args),
        });
    } else {
        try appendLazyDerivationAttr(self, &entries, attrs_id, "outPath");
    }
    for (output_names.names) |output_name| {
        try appendLazyDerivationAttrId(self, &entries, attrs_id, output_name);
    }
    try appendLazyDerivationAttr(self, &entries, attrs_id, "all");

    return Value.attrs(try self.heap.addAttrs(entries.items));
}

fn lazyOutputNamesList(self: *VM, names: []const InternId) !ObjectId {
    const values = try self.allocator.alloc(Value, names.len);
    defer self.allocator.free(values);
    for (names, values) |name, *value| value.* = Value.string(name);
    return self.heap.addList(values);
}

fn appendLazyDerivationAttr(
    self: *VM,
    entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry),
    attrs_id: ObjectId,
    name: []const u8,
) !void {
    try appendLazyDerivationAttrId(self, entries, attrs_id, try self.intern.intern(name));
}

fn appendLazyDerivationAttrId(
    self: *VM,
    entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry),
    attrs_id: ObjectId,
    name: InternId,
) !void {
    const args = [_]Value{ Value.attrs(attrs_id), Value.string(name) };
    try entries.append(self.allocator, .{
        .name = name,
        .value = try makeBuiltinThunk(self, .derivationLazyAttr, &args),
    });
}

fn derivationStructuredAttrs(self: *VM, attrs_id: ObjectId) !bool {
    const name = try self.intern.intern("__structuredAttrs");
    const value = self.heap.getAttrValue(attrs_id, name) catch |err| switch (err) {
        error.MissingAttribute => return false,
        else => return err,
    };
    const forced = try vm_force.forceValue(self, value);
    if (!forced.isBool()) return error.TypeError;
    return forced.asBool();
}

/// Validate a derivation `name` as a Nix store-path name: non-empty, at most
/// 211 chars, not `.`/`..`, and only `[A-Za-z0-9+._?=-]`.
fn validateDerivationName(self: *VM, name: []const u8) !void {
    if (derivation.store_name.isValid(name)) return;
    const msg = try std.fmt.allocPrint(self.allocator, "invalid derivation name '{s}'", .{name});
    defer self.allocator.free(msg);
    try vm_trace.setErrorMessage(self, msg);
    return error.InvalidDerivationName;
}

fn buildForcedDerivationValue(self: *VM, attrs_id: ObjectId, mode: DerivationMode) !Value {
    // GC: `attrs_id` is a bare id held across the whole (force-heavy) build.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, Value.attrs(attrs_id));

    var header = try readDerivationHeader(self, attrs_id);
    defer header.deinit(self.allocator);

    var observation = self.observer.begin(&compute_derivation_observation, .{
        .subject = .{ .text = header.name },
    });
    defer observation.cancel();

    var artifact = try computeDerivationArtifact(self, attrs_id, header);
    defer artifact.deinit(self);
    try recordDerivationArtifact(self, &artifact);
    const value = try buildDerivationResult(self, attrs_id, mode, header, &artifact.normalized, artifact.computed.drv_path);

    observation.finish(.{
        .details = .{
            .subject = .{ .text = header.name },
            .destination = .{ .path = artifact.computed.drv_path },
        },
        .metrics = &.{.{
            .name = "outputs",
            .value = .{ .unsigned = header.outputs.names.len },
            .unit = .items,
        }},
    });
    return value;
}

const DerivationHeader = struct {
    name: []const u8,
    outputs: DerivationOutputNames,

    fn deinit(self: *DerivationHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.outputs.names);
    }
};

fn readDerivationHeader(self: *VM, attrs_id: ObjectId) !DerivationHeader {
    const name_id = try self.intern.intern("name");
    const name_value = try vm_force.forceValue(self, try self.heap.getAttrValue(attrs_id, name_id));
    if (!isPlainString(name_value)) return error.TypeError;
    const drv_name_id = try strings.stringNameId(self, name_value);
    const drv_name = self.intern.get(drv_name_id);
    try validateDerivationName(self, drv_name);

    return .{
        .name = drv_name,
        .outputs = try derivationOutputNames(self, attrs_id),
    };
}

const DerivationArtifact = struct {
    normalized: NormalizedDerivation,
    computed: derivation.ComputedPaths,
    aterm_owned: bool = true,

    fn deinit(self: *DerivationArtifact, vm: *VM) void {
        self.normalized.deinit(vm.allocator);
        vm.allocator.free(self.computed.drv_path);
        self.computed.hash_modulo.deinit(vm.allocator);
        vm.allocator.free(self.computed.drv_text_references);
        if (self.aterm_owned) vm.realization.allocator.free(self.computed.drv_aterm);
    }
};

fn computeDerivationArtifact(self: *VM, attrs_id: ObjectId, header: DerivationHeader) !DerivationArtifact {
    const t_norm = prof.start(.drv_normalize);
    var normalized = normalizeDerivation(self, attrs_id, header.name, header.outputs) catch |err| {
        prof.end(.drv_normalize, t_norm);
        return err;
    };
    prof.end(.drv_normalize, t_norm);
    errdefer normalized.deinit(self.allocator);

    const t_comp = prof.start(.drv_compute);
    const computed = normalized.drv.computePathsWithPayloadAllocator(
        self.allocator,
        self.realization.allocator,
        self.realization.resolver(),
    ) catch |err| {
        prof.end(.drv_compute, t_comp);
        return err;
    };
    prof.end(.drv_compute, t_comp);
    return .{ .normalized = normalized, .computed = computed };
}

fn recordDerivationArtifact(self: *VM, artifact: *DerivationArtifact) !void {
    const computed = artifact.computed;
    try self.realization.record(computed.drv_path, computed.hash_modulo.view(), artifact.normalized.drv.outputs);
    try self.realization.recordDebug(&artifact.normalized.drv, computed);
    // Render the ATerm exactly once and transfer that allocation to the store's
    // recipe graph. `recordOwnedTextRecipe` only records an in-memory recipe;
    // the `.drv` is written to the store on demand (see `ensureClosure`), and
    // the `.store` progress span is reported there, at the actual write — not
    // here, where every instantiated derivation (demanded or not) passes.
    // recordOwnedTextRecipe consumes drv_aterm on success and error.
    artifact.aterm_owned = false;
    try self.realization.recordOwnedTextRecipe(
        computed.drv_path,
        computed.drv_aterm,
        computed.drv_text_references,
    );

    // Read-write eval is the one eager mode: legacy nix-instantiate promises
    // that every derivation demanded during evaluation is instantiated even
    // though the command still prints the evaluated value. Normal
    // instantiate/build stay terminal-closure-driven to avoid materializing
    // speculative or unrelated derivations.
    if (self.realization.eagerEvaluationWritesEnabled())
        try self.realization.ensureClosure(computed.drv_path);
}

fn buildDerivationResult(
    self: *VM,
    attrs_id: ObjectId,
    mode: DerivationMode,
    header: DerivationHeader,
    normalized: *const NormalizedDerivation,
    drv_path: []const u8,
) !Value {
    // Instantiation deliberately does NOT build the derivation. Instantiating
    // a derivation only means it was evaluated — not that its output is needed.
    // Building is reserved for
    // exactly what a stock `nix build` realizes: the requested output's closure
    // (the final authoritative `buildPaths`) plus any output demanded mid-eval via
    // IFD (`demandPathArg`). Eagerly building every instantiated `.drv` here also
    // built derivations OUTSIDE the output closure, and nondeterministically so —
    // which instantiation won the demand-vs-speculation race decided the set —
    // burning builder time for no output.

    const outputs = try self.allocator.alloc(derivation.ValueOutput, header.outputs.names.len);
    defer self.allocator.free(outputs);
    for (header.outputs.names, outputs) |output_name, *output| {
        const path = normalized.outputPath(self.intern.get(output_name)) orelse return error.InvalidDerivationOutput;
        output.* = .{
            .name = output_name,
            .out_path = try self.intern.intern(path),
        };
    }

    const spec: derivation.ValueSpec = .{
        .drv_path = try self.intern.intern(drv_path),
        .default_output = header.outputs.names[0],
        .outputs = outputs,
        .explicit_outputs = header.outputs.explicit,
        .original_attrs = try self.heap.materializeAttrs(attrs_id),
    };
    const t_bv = prof.start(.drv_build_value);
    defer prof.end(.drv_build_value, t_bv);
    const value = try switch (mode) {
        .lazy => derivation.buildValue(self.allocator, self.intern, self.heap, spec),
        .strict => derivation.buildStrictValue(self.allocator, self.intern, self.heap, spec),
    };
    return value;
}

const NormalizedDerivation = struct {
    drv: derivation.Drv,
    owned_strings: std.ArrayListUnmanaged([]u8),
    owned_output_lists: std.ArrayListUnmanaged([]const []const u8),

    fn deinit(self: *NormalizedDerivation, allocator: std.mem.Allocator) void {
        for (self.drv.outputs) |output| {
            if (output.path.len != 0) allocator.free(output.path);
        }
        allocator.free(self.drv.outputs);
        allocator.free(self.drv.args);
        allocator.free(self.drv.env);
        allocator.free(self.drv.input_drvs);
        allocator.free(self.drv.input_srcs);
        for (self.owned_output_lists.items) |list| allocator.free(list);
        self.owned_output_lists.deinit(allocator);
        for (self.owned_strings.items) |string| allocator.free(string);
        self.owned_strings.deinit(allocator);
    }

    fn outputPath(self: *const NormalizedDerivation, name: []const u8) ?[]const u8 {
        for (self.drv.outputs) |output| {
            if (std.mem.eql(u8, output.name, name)) return output.path;
        }
        return null;
    }
};

fn normalizeDerivation(self: *VM, attrs_id: ObjectId, drv_name: []const u8, output_names: DerivationOutputNames) !NormalizedDerivation {
    var owned_strings: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (owned_strings.items) |string| self.allocator.free(string);
        owned_strings.deinit(self.allocator);
    }
    var owned_output_lists: std.ArrayListUnmanaged([]const []const u8) = .empty;
    errdefer {
        for (owned_output_lists.items) |list| self.allocator.free(list);
        owned_output_lists.deinit(self.allocator);
    }
    // Interned text (`intern.get`) is stable for the evaluator's lifetime
    // (append-only StableSegments), and everything downstream that needs a
    // build's strings beyond the build itself (`RealizationStore.record`,
    // `recordDebug`) clones its own copies. So strings that are already
    // interned — the name, output/attr names, whole env values with no
    // rewritten context — are used as-is instead of being duped into
    // `owned_strings`; the dupes were pure alloc+memcpy waste on the
    // (serial) normalize path. Only freshly-assembled strings are owned.
    const drv_name_owned = drv_name;

    const outputs = try self.allocator.alloc(derivation.DrvOutput, output_names.names.len);
    errdefer self.allocator.free(outputs);
    for (output_names.names, outputs) |name, *output| {
        output.* = .{ .name = self.intern.get(name) };
    }

    try applyFixedOutputAttrs(self, attrs_id, outputs, &owned_strings);

    var inputs = DerivationInputs{};
    defer inputs.deinit(self.allocator);

    const args = try derivationArgs(self, attrs_id, &inputs, &owned_strings);
    errdefer self.allocator.free(args);
    const system = try requiredDerivationString(self, attrs_id, "system", &inputs, &owned_strings);
    const builder = try requiredDerivationString(self, attrs_id, "builder", &inputs, &owned_strings);
    const structured = try derivationStructuredAttrs(self, attrs_id);
    const ignore_nulls = try derivationIgnoreNulls(self, attrs_id);

    var env: std.ArrayListUnmanaged(derivation.EnvVar) = .empty;
    errdefer env.deinit(self.allocator);
    const original_attrs = try self.heap.materializeAttrs(attrs_id);
    if (structured) {
        const json = try structuredAttrsJson(self, attrs_id, output_names.names, output_names.explicit, ignore_nulls, &inputs, &owned_strings);
        try owned_strings.append(self.allocator, json);
        try env.append(self.allocator, .{ .name = "__json", .value = json });
    } else {
        // Fan out before the sequential walk: every attr's value will be
        // forced (either the null-check or `derivationAttrString` reaches
        // it), and each force is independent. Helpers race the main
        // walker — by the time main reaches an attr, the helper has
        // often already resolved it. submitUrgent gives up silently if
        // the queues are full; main just forces those itself inline.
        for (original_attrs.values) |entry_value| {
            if (!entry_value.isThunk()) continue;
            const ok = self.workers.submitUrgentThunk(entry_value.asObjectId(), self.workerId());
            if (!ok) break;
        }
        const attrs_len = original_attrs.len();
        var ai: usize = 0;
        while (ai < attrs_len) : (ai += 1) {
            const cur_view = try self.heap.materializeAttrs(attrs_id);
            const entry_name_id = cur_view.names[ai];
            const entry_value = cur_view.values[ai];
            // Interned attr name — stable, no dupe (see note above).
            const attr_name = self.intern.get(entry_name_id);
            if (std.mem.eql(u8, attr_name, "args")) continue;
            if (std.mem.eql(u8, attr_name, "__ignoreNulls")) continue;
            if (ignore_nulls and (try vm_force.forceValue(self, entry_value)).isNull()) continue;
            if (isDerivationOutputAttr(self, attr_name, output_names.names)) continue;
            if (std.mem.eql(u8, attr_name, "outputs")) {
                if (output_names.explicit) {
                    const joined = try joinedOutputNames(self, output_names.names);
                    try owned_strings.append(self.allocator, joined);
                    try env.append(self.allocator, .{ .name = "outputs", .value = joined });
                }
                continue;
            }
            const text = try derivationAttrString(self, entry_value, &inputs, &owned_strings);
            // A user-provided `__json` is the pre-serialized structured-attrs
            // payload — it must be valid JSON, else the derivation is rejected.
            if (std.mem.eql(u8, attr_name, "__json") and !(std.json.validate(self.allocator, text) catch false)) {
                try vm_trace.setErrorMessage(self, "cannot process __json: not valid JSON");
                return error.InvalidDerivation;
            }
            try env.append(self.allocator, .{ .name = attr_name, .value = text });
        }
    }
    for (outputs) |output| {
        try env.append(self.allocator, .{ .name = output.name, .value = "" });
    }

    const input_drvs = try inputs.input_drvs.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(input_drvs);
    const input_srcs = try inputs.input_srcs.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(input_srcs);
    owned_output_lists = inputs.owned_output_lists;
    inputs.owned_output_lists = .empty;

    return .{
        .drv = .{
            .name = drv_name_owned,
            .outputs = outputs,
            .input_drvs = input_drvs,
            .input_srcs = input_srcs,
            .system = system,
            .builder = builder,
            .args = args,
            .env = try env.toOwnedSlice(self.allocator),
        },
        .owned_strings = owned_strings,
        .owned_output_lists = owned_output_lists,
    };
}

fn applyFixedOutputAttrs(
    self: *VM,
    attrs_id: ObjectId,
    outputs: []derivation.DrvOutput,
    owned_strings: *std.ArrayListUnmanaged([]u8),
) !void {
    const hash_value = self.heap.getAttrValue(attrs_id, try self.intern.intern("outputHash")) catch |err| switch (err) {
        error.MissingAttribute => return,
        else => return err,
    };
    if (outputs.len != 1) return error.InvalidDerivationOutput;
    const hash_forced = try vm_force.forceValue(self, hash_value);
    if (!isPlainString(hash_forced)) return error.TypeError;
    const mode = blk: {
        const mode_value = self.heap.getAttrValue(attrs_id, try self.intern.intern("outputHashMode")) catch |err| switch (err) {
            error.MissingAttribute => break :blk "flat",
            else => return err,
        };
        const forced = try vm_force.forceValue(self, mode_value);
        if (!isPlainString(forced)) return error.TypeError;
        break :blk try vm_strings.stringBytes(self, forced);
    };
    const hash_text = try vm_strings.stringBytes(self, hash_forced);
    const algo = try fixedOutputHashAlgorithm(self, attrs_id, hash_text);
    const hash_hex = derivation.hashToBase16(self.allocator, algo, hash_text) catch |err| switch (err) {
        error.InvalidHashAlgorithm => {
            const msg = try std.fmt.allocPrint(self.allocator, "hash '{s}' should have type '{s}'", .{ hash_text, algo });
            defer self.allocator.free(msg);
            try vm_trace.setErrorMessage(self, msg);
            return err;
        },
        error.InvalidHash => {
            const msg = try std.fmt.allocPrint(self.allocator, "invalid hash '{s}'", .{hash_text});
            defer self.allocator.free(msg);
            try vm_trace.setErrorMessage(self, msg);
            return err;
        },
        else => return err,
    };
    errdefer self.allocator.free(hash_hex);
    try owned_strings.append(self.allocator, hash_hex);
    const hash_algo = if (std.mem.eql(u8, mode, "recursive")) blk: {
        const text = try std.fmt.allocPrint(self.allocator, "r:{s}", .{algo});
        errdefer self.allocator.free(text);
        try owned_strings.append(self.allocator, text);
        break :blk text;
    } else if (std.mem.eql(u8, mode, "flat")) blk: {
        // `algo` is interned text or a slice of it — stable, no dupe.
        break :blk algo;
    } else return error.InvalidHashMode;
    outputs[0].hash_algo = hash_algo;
    outputs[0].hash = hash_hex;
}

fn derivationIgnoreNulls(self: *VM, attrs_id: ObjectId) !bool {
    const value = self.heap.getAttrValue(attrs_id, try self.intern.intern("__ignoreNulls")) catch |err| switch (err) {
        error.MissingAttribute => return false,
        else => return err,
    };
    const forced = try vm_force.forceValue(self, value);
    if (!forced.isBool()) return error.TypeError;
    return forced.asBool();
}

fn fixedOutputHashAlgorithm(self: *VM, attrs_id: ObjectId, hash_text: []const u8) ![]const u8 {
    const algo_value = self.heap.getAttrValue(attrs_id, try self.intern.intern("outputHashAlgo")) catch |err| switch (err) {
        error.MissingAttribute => Value.null_val,
        else => return err,
    };
    const forced_algo = try vm_force.forceValue(self, algo_value);
    if (isPlainString(forced_algo)) {
        const algo = try vm_strings.stringBytes(self, forced_algo);
        if (algo.len != 0) return algo;
    } else if (!forced_algo.isNull()) return error.TypeError;

    const separator = derivation.hashAlgorithmSeparator(hash_text) orelse return error.InvalidHashAlgorithm;
    if (separator == 0) return error.InvalidHashAlgorithm;
    return hash_text[0..separator];
}

fn derivationArgs(
    self: *VM,
    attrs_id: ObjectId,
    inputs: *DerivationInputs,
    owned_strings: *std.ArrayListUnmanaged([]u8),
) ![]const []const u8 {
    const args_value = self.heap.getAttrValue(attrs_id, try self.intern.intern("args")) catch |err| switch (err) {
        error.MissingAttribute => return self.allocator.alloc([]const u8, 0),
        else => return err,
    };
    const list = try vm_force.forceValue(self, args_value);
    if (!list.isList()) return error.TypeError;
    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    const args = try self.allocator.alloc([]const u8, items.len);
    errdefer self.allocator.free(args);
    for (args, 0..) |*arg, i| arg.* = try derivationAttrString(self, try self.heap.getListItem(list_id, i), inputs, owned_strings);
    return args;
}

fn requiredDerivationString(
    self: *VM,
    attrs_id: ObjectId,
    name: []const u8,
    inputs: *DerivationInputs,
    owned_strings: *std.ArrayListUnmanaged([]u8),
) ![]const u8 {
    return derivationAttrString(self, try self.heap.getAttrValue(attrs_id, try self.intern.intern(name)), inputs, owned_strings);
}

fn derivationAttrString(
    self: *VM,
    value: Value,
    inputs: *DerivationInputs,
    owned_strings: *std.ArrayListUnmanaged([]u8),
) ![]const u8 {
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, value);
    const string_value = try coerceDerivationStringValue(self, value);
    vm_force.rootKeep(self, string_value);
    return normalizeDerivationString(self, string_value, inputs, owned_strings);
}

fn joinedOutputNames(self: *VM, names: []const InternId) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(self.allocator);
    for (names, 0..) |name, index| {
        if (index != 0) try out.append(self.allocator, ' ');
        try out.appendSlice(self.allocator, self.intern.get(name));
    }
    return out.toOwnedSlice(self.allocator);
}

fn structuredAttrsJson(
    self: *VM,
    attrs_id: ObjectId,
    outputs: []const InternId,
    explicit_outputs: bool,
    ignore_nulls: bool,
    inputs: *DerivationInputs,
    owned_strings: *std.ArrayListUnmanaged([]u8),
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(self.allocator);
    var seen: std.ArrayListUnmanaged(SeenJsonObject) = .empty;
    defer seen.deinit(self.allocator);

    var first = true;
    try out.append(self.allocator, '{');
    const entries = try sortedAttrEntries(self, Value.attrs(attrs_id));
    defer self.allocator.free(entries);
    for (entries) |entry| {
        const name = self.intern.get(entry.name);
        if (std.mem.eql(u8, name, "__structuredAttrs")) continue;
        if (std.mem.eql(u8, name, "__ignoreNulls")) continue;
        if (std.mem.eql(u8, name, "args")) continue;
        if (std.mem.eql(u8, name, "outputs") and !explicit_outputs) continue;
        if (isDerivationOutputAttr(self, name, outputs)) continue;
        if (ignore_nulls and (try vm_force.forceValue(self, entry.value)).isNull()) continue;
        if (!first) try out.append(self.allocator, ',');
        first = false;
        try appendJsonString(self, &out, self.intern.get(entry.name));
        try out.append(self.allocator, ':');
        try appendStructuredJsonValue(self, &out, entry.value, inputs, owned_strings, &seen);
    }
    try out.append(self.allocator, '}');
    return out.toOwnedSlice(self.allocator);
}

fn appendStructuredJsonValue(
    self: *VM,
    out: *std.ArrayListUnmanaged(u8),
    value: Value,
    inputs: *DerivationInputs,
    owned_strings: *std.ArrayListUnmanaged([]u8),
    seen: *std.ArrayListUnmanaged(SeenJsonObject),
) !void {
    const forced = try vm_force.forceValue(self, value);
    switch (forced.kind()) {
        .null => try out.appendSlice(self.allocator, "null"),
        .bool_false => try out.appendSlice(self.allocator, "false"),
        .bool_true => try out.appendSlice(self.allocator, "true"),
        .int => try appendJsonFmt(self, out, "{}", .{forced.asInt()}),
        .boxed_int => try appendJsonFmt(self, out, "{}", .{try self.heap.getBoxedInt(forced.asObjectId())}),
        .float => {
            var fbuf: [shared.json_float_buffer_size]u8 = undefined;
            try out.appendSlice(self.allocator, shared.jsonFloatText(&fbuf, forced.asFloat()));
        },
        .string, .path, .string_context, .heap_string => {
            try appendStructuredJsonStringValue(self, out, forced, inputs, owned_strings);
        },
        .list => {
            const list_id = forced.asObjectId();
            if (!try shared.enterJsonObject(self, .list, list_id, seen)) return error.RecursiveThunk;
            defer _ = seen.pop();

            try out.append(self.allocator, '[');
            const n = try self.heap.getListLen(list_id);
            var index: usize = 0;
            while (index < n) : (index += 1) {
                if (index != 0) try out.append(self.allocator, ',');
                try appendStructuredJsonValue(self, out, try self.heap.getListItem(list_id, index), inputs, owned_strings, seen);
            }
            try out.append(self.allocator, ']');
        },
        .attrs => {
            if (try jsonAttrsStringValue(self, forced)) |string_value| {
                try appendStructuredJsonStringValue(self, out, string_value, inputs, owned_strings);
                return;
            }

            const attrs_id = forced.asObjectId();
            if (!try shared.enterJsonObject(self, .attrs, attrs_id, seen)) return error.RecursiveThunk;
            defer _ = seen.pop();

            try out.append(self.allocator, '{');
            const entries = try sortedAttrEntries(self, forced);
            defer self.allocator.free(entries);
            for (entries, 0..) |entry, index| {
                if (index != 0) try out.append(self.allocator, ',');
                try appendJsonString(self, out, self.intern.get(entry.name));
                try out.append(self.allocator, ':');
                try appendStructuredJsonValue(self, out, entry.value, inputs, owned_strings, seen);
            }
            try out.append(self.allocator, '}');
        },
        .closure, .builtin, .builtin_closure, .partial_app => return error.TypeError,
        .thunk => unreachable,
    }
}

fn appendStructuredJsonStringValue(
    self: *VM,
    out: *std.ArrayListUnmanaged(u8),
    value: Value,
    inputs: *DerivationInputs,
    owned_strings: *std.ArrayListUnmanaged([]u8),
) !void {
    const string_value = try coerceDerivationStringValue(self, value);
    const text = try normalizeDerivationString(self, string_value, inputs, owned_strings);
    try appendJsonString(self, out, text);
}

fn appendJsonString(self: *VM, out: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    try out.append(self.allocator, '"');
    for (text) |char| switch (char) {
        '"' => try out.appendSlice(self.allocator, "\\\""),
        '\\' => try out.appendSlice(self.allocator, "\\\\"),
        '\n' => try out.appendSlice(self.allocator, "\\n"),
        '\r' => try out.appendSlice(self.allocator, "\\r"),
        '\t' => try out.appendSlice(self.allocator, "\\t"),
        else => try out.append(self.allocator, char),
    };
    try out.append(self.allocator, '"');
}

fn appendJsonFmt(self: *VM, out: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(self.allocator, fmt, args);
    defer self.allocator.free(text);
    try out.appendSlice(self.allocator, text);
}

fn isDerivationSyntheticAttr(self: *VM, attr_name: []const u8, outputs: []const InternId) bool {
    const synthetic = [_][]const u8{ "type", "outputName", "outPath", "drvPath", "drvAttrs", "all" };
    for (synthetic) |candidate| {
        if (std.mem.eql(u8, attr_name, candidate)) return true;
    }
    return isDerivationOutputAttr(self, attr_name, outputs);
}

fn isDerivationOutputAttr(self: *VM, attr_name: []const u8, outputs: []const InternId) bool {
    for (outputs) |output| {
        if (std.mem.eql(u8, attr_name, self.intern.get(output))) return true;
    }
    return false;
}

const DerivationInputs = struct {
    input_drvs: std.ArrayListUnmanaged(derivation.DrvInput) = .empty,
    input_srcs: std.ArrayListUnmanaged([]const u8) = .empty,
    owned_output_lists: std.ArrayListUnmanaged([]const []const u8) = .empty,

    fn deinit(self: *DerivationInputs, allocator: std.mem.Allocator) void {
        self.input_drvs.deinit(allocator);
        self.input_srcs.deinit(allocator);
        for (self.owned_output_lists.items) |list| allocator.free(list);
        self.owned_output_lists.deinit(allocator);
    }
};

fn normalizeDerivationString(
    self: *VM,
    value: Value,
    inputs: *DerivationInputs,
    owned_strings: *std.ArrayListUnmanaged([]u8),
) ![]const u8 {
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, value); // held across contextOutputs forces (below)
    const text = try vm_strings.stringBytes(self, value);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(self.allocator);
    var cursor: usize = 0;

    const ctx_view = try contextEntriesForValue(self, value);
    for (ctx_view.names, ctx_view.values) |entry_name, entry_value| {
        const path = self.intern.get(entry_name);
        if (std.mem.endsWith(u8, path, ".drv")) {
            // Marker-aware: `unsafeDiscardOutputDependency` leaves a plain
            // `path` marker on a `.drv`-named entry — that contributes the
            // drv FILE as an input source only, NOT an output dependency
            // (Nix parity; nixpkgs' cabalSdist tests grep drvPaths for
            // exactly this). Any output/allOutputs marker — or an unknown
            // marker shape, conservatively — keeps the input-drv edge.
            const marker = try vm_force.forceValue(self, entry_value);
            if (!marker.isAttrs()) return error.TypeError;
            const marker_id = marker.asObjectId();
            const has_path_marker = try contextMarkerHasAttr(self, marker_id, "path");
            const pure_path_marker = has_path_marker and
                !(try contextMarkerHasAttr(self, marker_id, "allOutputs")) and
                !(try contextMarkerHasAttr(self, marker_id, "outputs"));
            if (!pure_path_marker) {
                // `path` is interned — stable, no dupe (see normalizeDerivation).
                const outputs = try contextOutputs(self, path, entry_value);
                errdefer self.allocator.free(outputs);
                try inputs.owned_output_lists.append(self.allocator, outputs);
                try appendInputDrv(self, inputs, path, outputs);
            }
            if (has_path_marker or std.mem.indexOf(u8, text, path) != null)
                try appendInputSrc(self, inputs, path);
        } else {
            const store_path = try sourceStorePathForContext(self, path, owned_strings);
            try appendInputSrc(self, inputs, store_path);
            while (std.mem.indexOf(u8, text[cursor..], path)) |relative_index| {
                const index = cursor + relative_index;
                try out.appendSlice(self.allocator, text[cursor..index]);
                try out.appendSlice(self.allocator, store_path);
                cursor = index + path.len;
            }
        }
    }
    // No source-path rewrites — the text itself is the normalized string.
    // INTERNED text (plain strings, paths, context-string text) is stable
    // for the evaluator's lifetime, so skipping the dupe is safe and avoids
    // an alloc+memcpy per env value (build scripts run to KBs). A HEAP
    // string's bytes live only as long as the owning object — and here the
    // owner is often a fresh, otherwise-unreachable coercion result that
    // the caller unroots on return while the env walk keeps forcing (GC
    // safepoints): returning the borrow made later collections free and
    // re-hand the bytes under the slice, silently corrupting drv env text
    // (wrong drvPaths under tight budgets / FIX_GC_STEP_MB). Dupe those.
    if (out.items.len == 0) {
        if (!value.isHeapString()) return text;
        const copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(copy);
        try owned_strings.append(self.allocator, copy);
        return copy;
    }
    try out.appendSlice(self.allocator, text[cursor..]);
    const normalized = try out.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(normalized);
    try owned_strings.append(self.allocator, normalized);
    return normalized;
}

fn sourceStorePathForContext(self: *VM, path: []const u8, owned_strings: *std.ArrayListUnmanaged([]u8)) ![]const u8 {
    const store_path = try source_paths.storePathForSource(self.allocator, self.realization, self.files, path);
    errdefer self.allocator.free(store_path);
    try owned_strings.append(self.allocator, store_path);
    return store_path;
}

fn contextMarkerHasAttr(self: *VM, marker_id: ObjectId, name: []const u8) !bool {
    _ = self.heap.getAttrValue(marker_id, try self.intern.intern(name)) catch |err| switch (err) {
        error.MissingAttribute => return false,
        else => return err,
    };
    return true;
}

fn contextOutputs(
    self: *VM,
    path: []const u8,
    value: Value,
) ![]const []const u8 {
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    const attrs = try vm_force.forceValue(self, value);
    if (!attrs.isAttrs()) return error.TypeError;
    vm_force.rootKeep(self, attrs); // held across the outputs forces
    if (self.heap.getAttrValue(attrs.asObjectId(), try self.intern.intern("allOutputs"))) |all_outputs_value| {
        const all_outputs = try vm_force.forceValue(self, all_outputs_value);
        if (!all_outputs.isBool()) return error.TypeError;
        if (all_outputs.asBool()) {
            const known = self.realization.outputNames(path) orelse return error.UnknownInputDerivation;
            const outputs = try self.allocator.alloc([]const u8, known.len);
            errdefer self.allocator.free(outputs);
            // `RealizationStore.record` clones output names into store-owned
            // storage that outlives the build — no per-name dupe needed.
            @memcpy(outputs, known);
            return outputs;
        }
    } else |err| switch (err) {
        error.MissingAttribute => {},
        else => return err,
    }
    if (self.heap.getAttrValue(attrs.asObjectId(), try self.intern.intern("outputs"))) |outputs_value| {
        const list = try vm_force.forceValue(self, outputs_value);
        if (!list.isList()) return error.TypeError;
        const list_id = list.asObjectId();
        const items = try self.heap.getList(list_id);
        const outputs = try self.allocator.alloc([]const u8, items.len);
        errdefer self.allocator.free(outputs);
        for (outputs, 0..) |*output, i| {
            const item_value = try vm_force.forceValue(self, try self.heap.getListItem(list_id, i));
            if (!isPlainString(item_value)) return error.TypeError;
            // Interned — stable, no dupe (see normalizeDerivation).
            output.* = try vm_strings.stringBytes(self, item_value);
        }
        return outputs;
    } else |err| switch (err) {
        error.MissingAttribute => {},
        else => return err,
    }
    const fallback = try self.allocator.alloc([]const u8, 1);
    fallback[0] = "out"; // static literal — no dupe
    return fallback;
}

fn appendInputDrv(self: *VM, inputs: *DerivationInputs, path: []const u8, outputs: []const []const u8) !void {
    for (inputs.input_drvs.items) |*input| {
        if (std.mem.eql(u8, input.path, path)) {
            input.outputs = try unionOutputNames(self, inputs, input.outputs, outputs);
            return;
        }
    }
    try inputs.input_drvs.append(self.allocator, .{ .path = path, .outputs = outputs });
}

fn unionOutputNames(self: *VM, inputs: *DerivationInputs, a: []const []const u8, b: []const []const u8) ![]const []const u8 {
    var merged: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer merged.deinit(self.allocator);
    for (a) |name| try appendUniqueOutputName(self, &merged, name);
    for (b) |name| try appendUniqueOutputName(self, &merged, name);
    const list = try merged.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(list);
    try inputs.owned_output_lists.append(self.allocator, list);
    return list;
}

fn appendUniqueOutputName(self: *VM, outputs: *std.ArrayListUnmanaged([]const u8), name: []const u8) !void {
    for (outputs.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try outputs.append(self.allocator, name);
}

fn appendInputSrc(self: *VM, inputs: *DerivationInputs, path: []const u8) !void {
    for (inputs.input_srcs.items) |src| {
        if (std.mem.eql(u8, src, path)) return;
    }
    try inputs.input_srcs.append(self.allocator, path);
}

const DerivationOutputNames = struct {
    names: []InternId,
    explicit: bool,
};

fn derivationOutputNames(self: *VM, attrs_id: ObjectId) !DerivationOutputNames {
    const outputs_id = try self.intern.intern("outputs");
    const outputs_value = self.heap.getAttrValue(attrs_id, outputs_id) catch |err| switch (err) {
        error.MissingAttribute => {
            const names = try self.allocator.alloc(InternId, 1);
            names[0] = try self.intern.intern("out");
            return .{ .names = names, .explicit = false };
        },
        else => return err,
    };

    const outputs_list = try vm_force.forceValue(self, outputs_value);
    if (!outputs_list.isList()) return error.TypeError;
    // GC: `items` is a raw store slice held across the per-item forces below;
    // its owning list isn't otherwise rooted (this runs under the lazy path
    // where `attrs_id` isn't rooted by the caller).
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, outputs_list);
    const list_id = outputs_list.asObjectId();
    const items = try self.heap.getList(list_id);
    if (items.len == 0) return error.InvalidDerivationOutput;

    const names = try self.allocator.alloc(InternId, items.len);
    errdefer self.allocator.free(names);
    for (names, 0..) |*name, i| {
        const value = try vm_force.forceValue(self, try self.heap.getListItem(list_id, i));
        if (!isPlainString(value)) return error.TypeError;
        name.* = try strings.stringNameId(self, value);
        if (self.intern.get(name.*).len == 0) return error.InvalidDerivationOutput;
    }
    // Reject duplicate output names (Nix errors before building the .drv).
    for (names, 0..) |n, i| {
        for (names[0..i]) |m| {
            if (n != m) continue;
            const msg = try std.fmt.allocPrint(self.allocator, "duplicate derivation output '{s}'", .{self.intern.get(n)});
            defer self.allocator.free(msg);
            try vm_trace.setErrorMessage(self, msg);
            return error.InvalidDerivationOutput;
        }
    }
    return .{ .names = names, .explicit = true };
}
