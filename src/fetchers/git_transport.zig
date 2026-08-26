//! libgit2 adapter for evaluator-owned Git sources.

const std = @import("std");
const clock = @import("base").clock;
const sync = @import("base").sync;

const c = @cImport({
    @cInclude("git2.h");
    @cInclude("time.h");
});

pub const Credentials = struct { username: []const u8, password: []const u8 };
pub const Reporter = struct {
    ctx: *anyopaque,
    report: *const fn (ctx: *anyopaque, downloaded: u64, total: u64) void,
};
pub const Options = struct {
    credentials: ?Credentials = null,
    reporter: ?Reporter = null,
    ca_file: ?[]const u8 = null,
    proxy_url: ?[]const u8 = null,
    connect_timeout_seconds: u32 = 15,
    stalled_timeout_seconds: u32 = 300,
};
pub const Result = struct {
    rev: [c.GIT_OID_SHA1_HEXSIZE]u8,
    rev_count: i64,
    last_modified: i64,
    last_modified_date: [14]u8,
};

/// Materialize a local repository without invoking the Git executable.
/// A pinned revision is exported from its tree; an unpinned worktree copies
/// the current contents of index-tracked paths, so dirty tracked changes are
/// retained while untracked files and repository metadata are excluded.
pub fn snapshotLocal(
    allocator: std.mem.Allocator,
    io: std.Io,
    repository_path: []const u8,
    destination: []const u8,
    rev: ?[]const u8,
    submodules: bool,
    shallow: bool,
) !Result {
    try ensureInitialized();
    const path_z = try allocator.dupeZ(u8, repository_path);
    defer allocator.free(path_z);
    var repo: ?*c.git_repository = null;
    try check(c.git_repository_open_ext(&repo, path_z.ptr, c.GIT_REPOSITORY_OPEN_CROSS_FS, null));
    defer c.git_repository_free(repo);

    const object = try resolveObject(allocator, repo.?, rev, null);
    defer c.git_object_free(object);
    var peeled: ?*c.git_object = null;
    try check(c.git_object_peel(&peeled, object, c.GIT_OBJECT_COMMIT));
    defer c.git_object_free(peeled);
    const commit: *c.git_commit = @ptrCast(peeled.?);

    try std.Io.Dir.cwd().createDirPath(io, destination);
    if (rev != null) {
        try exportCommit(allocator, io, repo.?, commit, repository_path, destination, submodules);
    } else {
        try copyTrackedWorktree(allocator, io, repo.?, repository_path, destination, submodules);
    }
    return resultFromCommit(repo.?, commit, shallow);
}

var init_mu: sync.BlockingMutex = .{};
var initialized = false;
var network_config_mu: sync.BlockingMutex = .{};
var network_config: GlobalNetworkConfig = .{};

/// libgit2 exposes certificate and timeout settings only as process globals.
/// Configure them once, immutably, so concurrent requests never race and a
/// request can never inherit another request's policy by accident.
const GlobalNetworkConfig = struct {
    configured: bool = false,
    ca_len: ?usize = null,
    ca: [std.fs.max_path_bytes]u8 = undefined,
    connect_timeout_seconds: u32 = 0,
    stalled_timeout_seconds: u32 = 0,
};

fn ensureInitialized() !void {
    init_mu.lock();
    defer init_mu.unlock();
    if (initialized) return;
    if (c.git_libgit2_init() < 0) return error.GitInitializationFailed;
    initialized = true;
}

fn ensureNetworkConfig(options: Options, ca_z: ?[:0]u8) !void {
    network_config_mu.lock();
    defer network_config_mu.unlock();

    if (network_config.configured) {
        const ca_matches = if (options.ca_file) |path|
            network_config.ca_len != null and
                network_config.ca_len.? == path.len and
                std.mem.eql(u8, network_config.ca[0..path.len], path)
        else
            network_config.ca_len == null;
        if (!ca_matches or
            network_config.connect_timeout_seconds != options.connect_timeout_seconds or
            network_config.stalled_timeout_seconds != options.stalled_timeout_seconds)
        {
            return error.GitGlobalConfigurationConflict;
        }
        return;
    }

    if (options.ca_file) |path| {
        if (path.len > network_config.ca.len) return error.NameTooLong;
        const value = ca_z orelse unreachable;
        try check(c.git_libgit2_opts(
            c.GIT_OPT_SET_SSL_CERT_LOCATIONS,
            value.ptr,
            @as(?[*:0]const u8, null),
        ));
        @memcpy(network_config.ca[0..path.len], path);
        network_config.ca_len = path.len;
    }
    try check(c.git_libgit2_opts(
        c.GIT_OPT_SET_SERVER_CONNECT_TIMEOUT,
        timeoutMilliseconds(options.connect_timeout_seconds),
    ));
    try check(c.git_libgit2_opts(
        c.GIT_OPT_SET_SERVER_TIMEOUT,
        timeoutMilliseconds(options.stalled_timeout_seconds),
    ));
    network_config.connect_timeout_seconds = options.connect_timeout_seconds;
    network_config.stalled_timeout_seconds = options.stalled_timeout_seconds;
    network_config.configured = true;
}

fn timeoutMilliseconds(seconds: u32) c_int {
    return @intCast(@min(seconds *| 1000, std.math.maxInt(c_int)));
}

const CallbackContext = struct {
    username: ?[*:0]const u8 = null,
    password: ?[*:0]const u8 = null,
    proxy_url: ?[*:0]const u8 = null,
    credential_origin: ?[*:0]const u8 = null,
    reporter: ?Reporter = null,

    fn credentials(out: [*c]?*c.git_credential, url: [*c]const u8, username_from_url: [*c]const u8, allowed: c_uint, payload: ?*anyopaque) callconv(.c) c_int {
        const self: *CallbackContext = @ptrCast(@alignCast(payload orelse return c.GIT_PASSTHROUGH));
        const same_origin = if (self.credential_origin) |origin|
            sameAuthority(std.mem.span(origin), std.mem.span(url))
        else
            false;
        if ((allowed & c.GIT_CREDENTIAL_USERPASS_PLAINTEXT) != 0 and same_origin and self.username != null and self.password != null)
            return c.git_credential_userpass_plaintext_new(out, self.username.?, self.password.?);
        if ((allowed & c.GIT_CREDENTIAL_SSH_KEY) != 0) {
            const username: [*c]const u8 = if (username_from_url != null) username_from_url else "git";
            return c.git_credential_ssh_key_from_agent(out, username);
        }
        if ((allowed & c.GIT_CREDENTIAL_USERNAME) != 0) {
            const username: [*c]const u8 = if (username_from_url != null) username_from_url else "git";
            return c.git_credential_username_new(out, username);
        }
        if ((allowed & c.GIT_CREDENTIAL_DEFAULT) != 0) return c.git_credential_default_new(out);
        return c.GIT_PASSTHROUGH;
    }

    fn transfer(stats: [*c]const c.git_indexer_progress, payload: ?*anyopaque) callconv(.c) c_int {
        const self: *CallbackContext = @ptrCast(@alignCast(payload orelse return 0));
        const reporter = self.reporter orelse return 0;
        const done = if (stats != null) stats.*.received_bytes else 0;
        reporter.report(reporter.ctx, done, 0);
        return 0;
    }
};

fn sameAuthority(a: []const u8, b: []const u8) bool {
    const authority = struct {
        fn of(url: []const u8) []const u8 {
            const start = if (std.mem.indexOf(u8, url, "://")) |index| index + 3 else 0;
            const end = std.mem.indexOfScalarPos(u8, url, start, '/') orelse url.len;
            return url[start..end];
        }
    }.of;
    return std.ascii.eqlIgnoreCase(authority(a), authority(b));
}

fn configureCallbacks(callbacks: *c.git_remote_callbacks, context: *CallbackContext) !void {
    if (c.git_remote_init_callbacks(callbacks, c.GIT_REMOTE_CALLBACKS_VERSION) < 0) return gitError();
    callbacks.credentials = CallbackContext.credentials;
    callbacks.transfer_progress = CallbackContext.transfer;
    callbacks.payload = context;
}

fn configureFetch(fetch: *c.git_fetch_options, context: *CallbackContext) !void {
    try configureCallbacks(&fetch.callbacks, context);
    fetch.proxy_opts.type = if (context.proxy_url != null) c.GIT_PROXY_SPECIFIED else c.GIT_PROXY_AUTO;
    fetch.proxy_opts.url = context.proxy_url;
    fetch.proxy_opts.credentials = CallbackContext.credentials;
    fetch.proxy_opts.payload = context;
}

fn gitError() anyerror {
    const last = c.git_error_last();
    if (last != null and last.*.klass == c.GIT_ERROR_NET) return error.FetchTransient;
    return error.FetchGitFailed;
}

fn check(code: c_int) !void {
    if (code < 0) return gitError();
}

/// Clone or refresh a worktree, resolve the requested commit, then cleanly
/// check it out. `refresh=false` still opens and validates the existing cache.
pub fn materialize(
    allocator: std.mem.Allocator,
    url: []const u8,
    path: []const u8,
    rev: ?[]const u8,
    ref_name: ?[]const u8,
    submodules: bool,
    all_refs: bool,
    shallow: bool,
    refresh: bool,
    options: Options,
) !Result {
    try ensureInitialized();
    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const username_z = if (options.credentials) |cred| try allocator.dupeZ(u8, cred.username) else null;
    defer if (username_z) |value| allocator.free(value);
    const password_z = if (options.credentials) |cred| try allocator.dupeZ(u8, cred.password) else null;
    defer if (password_z) |value| allocator.free(value);
    const ca_z = if (options.ca_file) |value| try allocator.dupeZ(u8, value) else null;
    defer if (ca_z) |value| allocator.free(value);
    const proxy_z = if (options.proxy_url) |value| try allocator.dupeZ(u8, value) else null;
    defer if (proxy_z) |value| allocator.free(value);
    try ensureNetworkConfig(options, ca_z);

    var context = CallbackContext{
        .username = if (username_z) |value| value.ptr else null,
        .password = if (password_z) |value| value.ptr else null,
        .proxy_url = if (proxy_z) |value| value.ptr else null,
        .credential_origin = url_z.ptr,
        .reporter = options.reporter,
    };
    const refspec = try fetchRefspec(allocator, rev, ref_name, all_refs);
    defer allocator.free(refspec);
    var repo: ?*c.git_repository = null;
    if (c.git_repository_open(&repo, path_z.ptr) < 0) {
        try check(c.git_repository_init(&repo, path_z.ptr, 0));
        var remote: ?*c.git_remote = null;
        try check(c.git_remote_create_with_fetchspec(&remote, repo.?, "origin", url_z.ptr, refspec.ptr));
        defer c.git_remote_free(remote);
        try fetchTargeted(allocator, remote.?, refspec, rev, ref_name, all_refs, shallow, &context);
    } else if (refresh) {
        var remote: ?*c.git_remote = null;
        try check(c.git_remote_lookup(&remote, repo.?, "origin"));
        defer c.git_remote_free(remote);
        try fetchTargeted(allocator, remote.?, refspec, rev, ref_name, all_refs, shallow, &context);
    }
    defer c.git_repository_free(repo);

    const object = try resolveObject(allocator, repo.?, rev, ref_name);
    defer c.git_object_free(object);
    var peeled: ?*c.git_object = null;
    try check(c.git_object_peel(&peeled, object, c.GIT_OBJECT_COMMIT));
    defer c.git_object_free(peeled);
    const commit: *c.git_commit = @ptrCast(peeled.?);
    const oid = c.git_commit_id(commit);

    var checkout: c.git_checkout_options = undefined;
    try check(c.git_checkout_options_init(&checkout, c.GIT_CHECKOUT_OPTIONS_VERSION));
    checkout.checkout_strategy = c.GIT_CHECKOUT_FORCE | c.GIT_CHECKOUT_RECREATE_MISSING | c.GIT_CHECKOUT_REMOVE_UNTRACKED;
    // Nix hashes the raw committed blobs, so gitattributes and autocrlf
    // filters must not rewrite them on checkout.
    checkout.disable_filters = 1;
    try check(c.git_checkout_tree(repo.?, peeled.?, &checkout));
    try check(c.git_repository_set_head_detached(repo.?, oid));
    if (submodules) try updateSubmodules(repo.?, &context);

    return resultFromCommit(repo.?, commit, shallow);
}

fn resultFromCommit(repo: *c.git_repository, commit: *c.git_commit, shallow: bool) !Result {
    const oid = c.git_commit_id(commit);
    var result: Result = undefined;
    var rev_z: [c.GIT_OID_SHA1_HEXSIZE + 1]u8 = undefined;
    _ = c.git_oid_tostr(&rev_z, rev_z.len, oid);
    @memcpy(&result.rev, rev_z[0..result.rev.len]);
    // No walking a truncated history: a requested shallow fetch counts as 0
    // (Nix's value for it), and an unrequested-shallow repository reports the
    // -1 sentinel so `revCount` can fail lazily on use, as in Nix.
    result.rev_count = if (shallow)
        0
    else if (c.git_repository_is_shallow(repo) == 1)
        -1
    else
        try revisionCount(repo, oid);
    result.last_modified = @intCast(c.git_commit_time(commit));
    result.last_modified_date = clock.formatUtc(result.last_modified);
    return result;
}

fn copyTrackedWorktree(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *c.git_repository,
    source_root: []const u8,
    destination_root: []const u8,
    submodules: bool,
) !void {
    var index: ?*c.git_index = null;
    try check(c.git_repository_index(&index, repo));
    defer c.git_index_free(index);
    const count = c.git_index_entrycount(index.?);
    var position: usize = 0;
    while (position < count) : (position += 1) {
        const entry = c.git_index_get_byindex(index.?, position) orelse continue;
        // Conflict stages live in the upper flag bits; only the normal stage
        // describes the tracked worktree snapshot.
        if ((entry.*.flags & c.GIT_INDEX_ENTRY_STAGEMASK) != 0) continue;
        const relative = std.mem.span(entry.*.path);
        const source = try std.fs.path.join(allocator, &.{ source_root, relative });
        defer allocator.free(source);
        const destination = try std.fs.path.join(allocator, &.{ destination_root, relative });
        defer allocator.free(destination);
        if (entry.*.mode == c.GIT_FILEMODE_COMMIT) {
            try std.Io.Dir.cwd().createDirPath(io, destination);
            if (submodules) {
                var child: ?*c.git_repository = null;
                const source_z = try allocator.dupeZ(u8, source);
                defer allocator.free(source_z);
                if (c.git_repository_open_ext(&child, source_z.ptr, c.GIT_REPOSITORY_OPEN_CROSS_FS, null) == 0) {
                    defer c.git_repository_free(child);
                    try copyTrackedWorktree(allocator, io, child.?, source, destination, true);
                }
            }
            continue;
        }
        const stat = std.Io.Dir.cwd().statFile(io, source, .{ .follow_symlinks = false }) catch continue;
        switch (stat.kind) {
            .sym_link => {
                const parent = std.fs.path.dirname(destination) orelse destination_root;
                try std.Io.Dir.cwd().createDirPath(io, parent);
                var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const length = try std.Io.Dir.readLinkAbsolute(io, source, &target_buffer);
                try std.Io.Dir.symLinkAbsolute(io, target_buffer[0..length], destination, .{});
            },
            .file => try std.Io.Dir.copyFileAbsolute(source, destination, io, .{ .make_path = true }),
            else => {},
        }
    }
}

fn exportCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *c.git_repository,
    commit: *c.git_commit,
    source_root: []const u8,
    destination_root: []const u8,
    submodules: bool,
) anyerror!void {
    var tree: ?*c.git_tree = null;
    try check(c.git_commit_tree(&tree, commit));
    defer c.git_tree_free(tree);
    try exportTree(allocator, io, repo, tree.?, source_root, destination_root, "", submodules);
}

fn exportTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *c.git_repository,
    tree: *c.git_tree,
    source_root: []const u8,
    destination_root: []const u8,
    prefix: []const u8,
    submodules: bool,
) anyerror!void {
    const count = c.git_tree_entrycount(tree);
    var position: usize = 0;
    while (position < count) : (position += 1) {
        const entry = c.git_tree_entry_byindex(tree, position) orelse continue;
        const name = std.mem.span(c.git_tree_entry_name(entry));
        const relative = if (prefix.len == 0)
            try allocator.dupe(u8, name)
        else
            try std.fs.path.join(allocator, &.{ prefix, name });
        defer allocator.free(relative);
        const destination = try std.fs.path.join(allocator, &.{ destination_root, relative });
        defer allocator.free(destination);
        const mode = c.git_tree_entry_filemode(entry);
        switch (mode) {
            c.GIT_FILEMODE_TREE => {
                try std.Io.Dir.cwd().createDirPath(io, destination);
                var child: ?*c.git_tree = null;
                try check(c.git_tree_lookup(&child, repo, c.git_tree_entry_id(entry)));
                defer c.git_tree_free(child);
                try exportTree(allocator, io, repo, child.?, source_root, destination_root, relative, submodules);
            },
            c.GIT_FILEMODE_BLOB, c.GIT_FILEMODE_BLOB_EXECUTABLE, c.GIT_FILEMODE_LINK => {
                var blob: ?*c.git_blob = null;
                try check(c.git_blob_lookup(&blob, repo, c.git_tree_entry_id(entry)));
                defer c.git_blob_free(blob);
                const raw: [*]const u8 = @ptrCast(c.git_blob_rawcontent(blob.?));
                const contents = raw[0..@intCast(c.git_blob_rawsize(blob.?))];
                const parent = std.fs.path.dirname(destination) orelse destination_root;
                try std.Io.Dir.cwd().createDirPath(io, parent);
                if (mode == c.GIT_FILEMODE_LINK) {
                    try std.Io.Dir.symLinkAbsolute(io, contents, destination, .{});
                } else {
                    try std.Io.Dir.cwd().writeFile(io, .{
                        .sub_path = destination,
                        .data = contents,
                        .flags = .{ .permissions = if (mode == c.GIT_FILEMODE_BLOB_EXECUTABLE) .executable_file else .default_file },
                    });
                }
            },
            c.GIT_FILEMODE_COMMIT => {
                try std.Io.Dir.cwd().createDirPath(io, destination);
                if (submodules) {
                    const source = try std.fs.path.join(allocator, &.{ source_root, relative });
                    defer allocator.free(source);
                    const source_z = try allocator.dupeZ(u8, source);
                    defer allocator.free(source_z);
                    var child_repo: ?*c.git_repository = null;
                    if (c.git_repository_open_ext(&child_repo, source_z.ptr, c.GIT_REPOSITORY_OPEN_CROSS_FS, null) == 0) {
                        defer c.git_repository_free(child_repo);
                        var child_object: ?*c.git_object = null;
                        try check(c.git_object_lookup(&child_object, child_repo.?, c.git_tree_entry_id(entry), c.GIT_OBJECT_COMMIT));
                        defer c.git_object_free(child_object);
                        const child_commit: *c.git_commit = @ptrCast(child_object.?);
                        try exportCommit(allocator, io, child_repo.?, child_commit, source, destination, true);
                    }
                }
            },
            else => {},
        }
    }
}

/// Fetch `refspec`, falling back for a pinned rev to the requested ref (or
/// HEAD): a rev fetches by OID where the transport negotiates it, as Nix
/// does, but some transports only accept advertised ref names, and the ref's
/// history must then contain the rev.
fn fetchTargeted(
    allocator: std.mem.Allocator,
    remote: *c.git_remote,
    refspec: [:0]const u8,
    rev: ?[]const u8,
    ref_name: ?[]const u8,
    all_refs: bool,
    shallow: bool,
    context: *CallbackContext,
) !void {
    var fetch_opts: c.git_fetch_options = undefined;
    try check(c.git_fetch_options_init(&fetch_opts, c.GIT_FETCH_OPTIONS_VERSION));
    try configureFetch(&fetch_opts, context);
    // Depth applies to the fallback fetch below as well, so a rev that has to
    // be reached through its ref still clones at depth 1.
    if (shallow) fetch_opts.depth = 1;
    var refspec_ptrs = [_][*c]u8{@constCast(refspec.ptr)};
    var refspecs = c.git_strarray{ .strings = &refspec_ptrs, .count = 1 };
    check(c.git_remote_fetch(remote, &refspecs, &fetch_opts, null)) catch |err| {
        if (rev == null or all_refs) return err;
        const fallback = try fetchRefspec(allocator, null, ref_name, false);
        defer allocator.free(fallback);
        var fallback_ptrs = [_][*c]u8{@constCast(fallback.ptr)};
        var fallback_refspecs = c.git_strarray{ .strings = &fallback_ptrs, .count = 1 };
        try check(c.git_remote_fetch(remote, &fallback_refspecs, &fetch_opts, null));
    };
}

/// The single refspec Nix fetches: everything under `allRefs`, the pinned rev
/// itself, or the one requested ref (a plain name means a branch, as in Nix);
/// the remote's HEAD when nothing is requested.
fn fetchRefspec(allocator: std.mem.Allocator, rev: ?[]const u8, ref_name: ?[]const u8, all_refs: bool) ![:0]u8 {
    if (all_refs) return allocator.dupeZ(u8, "+refs/*:refs/*");
    if (rev) |value| return std.fmt.allocPrintSentinel(allocator, "+{s}:refs/remotes/origin/pinned", .{value}, 0);
    if (ref_name) |value| {
        if (std.mem.startsWith(u8, value, "refs/"))
            return std.fmt.allocPrintSentinel(allocator, "+{s}:{s}", .{ value, value }, 0);
        return std.fmt.allocPrintSentinel(allocator, "+refs/heads/{s}:refs/remotes/origin/{s}", .{ value, value }, 0);
    }
    return allocator.dupeZ(u8, "+HEAD:refs/remotes/origin/HEAD");
}

fn resolveObject(allocator: std.mem.Allocator, repo: *c.git_repository, rev: ?[]const u8, ref_name: ?[]const u8) !*c.git_object {
    var candidates: [4]?[]u8 = @splat(null);
    defer for (candidates) |candidate| if (candidate) |value| allocator.free(value);
    var count: usize = 0;
    if (rev) |value| {
        candidates[count] = try allocator.dupe(u8, value);
        count += 1;
    } else if (ref_name) |value| {
        if (std.mem.startsWith(u8, value, "refs/heads/")) {
            candidates[count] = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{value["refs/heads/".len..]});
            count += 1;
        } else if (!std.mem.startsWith(u8, value, "refs/")) {
            candidates[count] = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{value});
            count += 1;
            candidates[count] = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{value});
            count += 1;
        }
        candidates[count] = try allocator.dupe(u8, value);
        count += 1;
    } else {
        candidates[count] = try allocator.dupe(u8, "refs/remotes/origin/HEAD");
        count += 1;
        candidates[count] = try allocator.dupe(u8, "HEAD");
        count += 1;
    }
    for (candidates[0..count]) |candidate| {
        const expression = try allocator.dupeZ(u8, candidate.?);
        defer allocator.free(expression);
        var object: ?*c.git_object = null;
        if (c.git_revparse_single(&object, repo, expression.ptr) == 0) return object.?;
    }
    return error.FetchGitRevisionNotFound;
}

fn revisionCount(repo: *c.git_repository, oid: *const c.git_oid) !i64 {
    var walk: ?*c.git_revwalk = null;
    try check(c.git_revwalk_new(&walk, repo));
    defer c.git_revwalk_free(walk);
    try check(c.git_revwalk_push(walk.?, oid));
    var next: c.git_oid = undefined;
    var count: i64 = 0;
    while (c.git_revwalk_next(&next, walk.?) == 0) count += 1;
    return count;
}

fn updateSubmodules(repo: *c.git_repository, context: *CallbackContext) !void {
    const State = struct {
        context: *CallbackContext,
        failed: bool = false,
        fn each(submodule: ?*c.git_submodule, _: [*c]const u8, payload: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(payload orelse return -1));
            var opts: c.git_submodule_update_options = undefined;
            if (c.git_submodule_update_options_init(&opts, c.GIT_SUBMODULE_UPDATE_OPTIONS_VERSION) < 0) return -1;
            configureFetch(&opts.fetch_opts, self.context) catch return -1;
            opts.checkout_opts.checkout_strategy = c.GIT_CHECKOUT_FORCE | c.GIT_CHECKOUT_RECREATE_MISSING | c.GIT_CHECKOUT_REMOVE_UNTRACKED;
            opts.checkout_opts.disable_filters = 1;
            if (c.git_submodule_update(submodule.?, 1, &opts) < 0) {
                self.failed = true;
                return -1;
            }
            var child: ?*c.git_repository = null;
            if (c.git_submodule_open(&child, submodule.?) == 0) {
                defer c.git_repository_free(child);
                updateSubmodules(child.?, self.context) catch {
                    self.failed = true;
                    return -1;
                };
            }
            return 0;
        }
    };
    var state = State{ .context = context };
    const code = c.git_submodule_foreach(repo, State.each, &state);
    if (code < 0 or state.failed) return gitError();
}

fn createTestCommit(allocator: std.mem.Allocator, repository_path: []const u8, message: []const u8) !void {
    try ensureInitialized();
    const path_z = try allocator.dupeZ(u8, repository_path);
    defer allocator.free(path_z);
    const message_z = try allocator.dupeZ(u8, message);
    defer allocator.free(message_z);
    var repo: ?*c.git_repository = null;
    if (c.git_repository_open(&repo, path_z.ptr) < 0)
        try check(c.git_repository_init(&repo, path_z.ptr, 0));
    defer c.git_repository_free(repo);

    var index: ?*c.git_index = null;
    try check(c.git_repository_index(&index, repo.?));
    defer c.git_index_free(index);
    try check(c.git_index_add_all(index.?, null, c.GIT_INDEX_ADD_DEFAULT, null, null));
    try check(c.git_index_write(index.?));
    var tree_oid: c.git_oid = undefined;
    try check(c.git_index_write_tree(&tree_oid, index.?));
    var tree: ?*c.git_tree = null;
    try check(c.git_tree_lookup(&tree, repo.?, &tree_oid));
    defer c.git_tree_free(tree);

    var signature: ?*c.git_signature = null;
    try check(c.git_signature_now(&signature, "Fix Test", "fix@example.invalid"));
    defer c.git_signature_free(signature);
    var parent_object: ?*c.git_object = null;
    defer if (parent_object) |object| c.git_object_free(object);
    var parent_peeled: ?*c.git_object = null;
    defer if (parent_peeled) |object| c.git_object_free(object);
    var parent_commit: ?*c.git_commit = null;
    if (c.git_revparse_single(&parent_object, repo.?, "HEAD") == 0) {
        try check(c.git_object_peel(&parent_peeled, parent_object.?, c.GIT_OBJECT_COMMIT));
        parent_commit = @ptrCast(parent_peeled.?);
    }
    var parents = [_]?*const c.git_commit{parent_commit};
    var commit_oid: c.git_oid = undefined;
    try check(c.git_commit_create(
        &commit_oid,
        repo.?,
        "HEAD",
        signature.?,
        signature.?,
        null,
        message_z.ptr,
        tree.?,
        @intFromBool(parent_commit != null),
        if (parent_commit != null) &parents else null,
    ));
}

test "libgit2 clone, refresh, checkout, and metadata" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "source", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/file", .data = "one" });
    const source = try tmp.dir.realPathFileAlloc(testing.io, "source", testing.allocator);
    defer testing.allocator.free(source);
    const clone = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(clone);
    const clone_path = try std.fs.path.join(testing.allocator, &.{ clone, "clone" });
    defer testing.allocator.free(clone_path);
    const url = try std.fmt.allocPrint(testing.allocator, "file://{s}", .{source});
    defer testing.allocator.free(url);

    try createTestCommit(testing.allocator, source, "one");

    const first = try materialize(testing.allocator, url, clone_path, null, null, false, false, false, true, .{});
    try testing.expectEqual(@as(i64, 1), first.rev_count);
    try testing.expect(first.last_modified > 0);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/file", .data = "two" });
    try createTestCommit(testing.allocator, source, "two");
    const second = try materialize(testing.allocator, url, clone_path, null, null, false, false, false, true, .{});
    try testing.expect(!std.mem.eql(u8, &first.rev, &second.rev));
    try testing.expectEqual(@as(i64, 2), second.rev_count);
}

test "materialize keeps raw blob bytes under gitattributes filters" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "source", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/.gitattributes", .data = "file text eol=crlf\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/file", .data = "one\ntwo\n" });
    const source = try tmp.dir.realPathFileAlloc(testing.io, "source", testing.allocator);
    defer testing.allocator.free(source);
    const clone = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(clone);
    const clone_path = try std.fs.path.join(testing.allocator, &.{ clone, "clone" });
    defer testing.allocator.free(clone_path);
    const url = try std.fmt.allocPrint(testing.allocator, "file://{s}", .{source});
    defer testing.allocator.free(url);

    try createTestCommit(testing.allocator, source, "one");
    _ = try materialize(testing.allocator, url, clone_path, null, null, false, false, false, true, .{});

    var clone_dir = try std.Io.Dir.cwd().openDir(testing.io, clone_path, .{});
    defer clone_dir.close(testing.io);
    const contents = try clone_dir.readFileAlloc(testing.io, "file", testing.allocator, .limited(64));
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("one\ntwo\n", contents);
}

test "materialize fetches only the requested object unless allRefs" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "source", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/file", .data = "one" });
    const source = try tmp.dir.realPathFileAlloc(testing.io, "source", testing.allocator);
    defer testing.allocator.free(source);
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const url = try std.fmt.allocPrint(testing.allocator, "file://{s}", .{source});
    defer testing.allocator.free(url);
    const source_z = try testing.allocator.dupeZ(u8, source);
    defer testing.allocator.free(source_z);

    try createTestCommit(testing.allocator, source, "one");
    // Grow a second branch so fetch breadth is observable, then return HEAD.
    var default_ref: [128]u8 = undefined;
    var default_len: usize = 0;
    {
        var repo: ?*c.git_repository = null;
        try check(c.git_repository_open(&repo, source_z.ptr));
        defer c.git_repository_free(repo);
        var head: ?*c.git_reference = null;
        try check(c.git_repository_head(&head, repo.?));
        defer c.git_reference_free(head);
        const name = std.mem.span(c.git_reference_name(head.?));
        default_len = name.len;
        @memcpy(default_ref[0..name.len], name);
        var commit: ?*c.git_object = null;
        try check(c.git_revparse_single(&commit, repo.?, "HEAD"));
        defer c.git_object_free(commit);
        var branch: ?*c.git_reference = null;
        try check(c.git_branch_create(&branch, repo.?, "feature", @ptrCast(commit.?), 0));
        c.git_reference_free(branch);
        try check(c.git_repository_set_head(repo.?, "refs/heads/feature"));
    }
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/file", .data = "two" });
    try createTestCommit(testing.allocator, source, "two");
    var feature_rev: [c.GIT_OID_SHA1_HEXSIZE:0]u8 = undefined;
    {
        var repo: ?*c.git_repository = null;
        try check(c.git_repository_open(&repo, source_z.ptr));
        defer c.git_repository_free(repo);
        var tip: ?*c.git_object = null;
        try check(c.git_revparse_single(&tip, repo.?, "refs/heads/feature"));
        defer c.git_object_free(tip);
        _ = c.git_oid_tostr(&feature_rev, feature_rev.len + 1, c.git_object_id(tip.?));
        const default_z = try testing.allocator.dupeZ(u8, default_ref[0..default_len]);
        defer testing.allocator.free(default_z);
        try check(c.git_repository_set_head(repo.?, default_z.ptr));
    }
    const hasFeatureTip = struct {
        fn in(alloc: std.mem.Allocator, clone_path: []const u8, spec: []const u8) !bool {
            const clone_z = try alloc.dupeZ(u8, clone_path);
            defer alloc.free(clone_z);
            const spec_z = try alloc.dupeZ(u8, spec);
            defer alloc.free(spec_z);
            var repo: ?*c.git_repository = null;
            try check(c.git_repository_open(&repo, clone_z.ptr));
            defer c.git_repository_free(repo);
            var object: ?*c.git_object = null;
            if (c.git_revparse_single(&object, repo.?, spec_z.ptr) < 0) return false;
            c.git_object_free(object);
            return true;
        }
    }.in;

    const head_clone = try std.fs.path.join(testing.allocator, &.{ root, "head" });
    defer testing.allocator.free(head_clone);
    const head_only = try materialize(testing.allocator, url, head_clone, null, null, false, false, false, true, .{});
    try testing.expectEqual(@as(i64, 1), head_only.rev_count);
    // The local transport copies the whole object store, so breadth shows in
    // the ref layout: a HEAD fetch must not track the other branch.
    try testing.expect(!try hasFeatureTip(testing.allocator, head_clone, "refs/heads/feature"));
    try testing.expect(!try hasFeatureTip(testing.allocator, head_clone, "refs/remotes/origin/feature"));

    const all_clone = try std.fs.path.join(testing.allocator, &.{ root, "all" });
    defer testing.allocator.free(all_clone);
    _ = try materialize(testing.allocator, url, all_clone, null, null, false, true, false, true, .{});
    try testing.expect(try hasFeatureTip(testing.allocator, all_clone, "refs/heads/feature"));

    const rev_clone = try std.fs.path.join(testing.allocator, &.{ root, "rev" });
    defer testing.allocator.free(rev_clone);
    const pinned = try materialize(testing.allocator, url, rev_clone, &feature_rev, null, false, false, false, true, .{});
    try testing.expectEqualStrings(&feature_rev, &pinned.rev);
}

test "shallow snapshots skip revCount; a truncated history reports the sentinel" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "source", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/file", .data = "one" });
    const source = try tmp.dir.realPathFileAlloc(testing.io, "source", testing.allocator);
    defer testing.allocator.free(source);
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    try createTestCommit(testing.allocator, source, "one");

    const full_dest = try std.fs.path.join(testing.allocator, &.{ root, "full" });
    defer testing.allocator.free(full_dest);
    const full = try snapshotLocal(testing.allocator, testing.io, source, full_dest, null, false, false);
    try testing.expectEqual(@as(i64, 1), full.rev_count);

    const shallow_dest = try std.fs.path.join(testing.allocator, &.{ root, "shallow" });
    defer testing.allocator.free(shallow_dest);
    const shallow = try snapshotLocal(testing.allocator, testing.io, source, shallow_dest, null, false, true);
    try testing.expectEqual(@as(i64, 0), shallow.rev_count);
    try testing.expectEqualStrings(&full.rev, &shallow.rev);

    // A repository is shallow exactly when `.git/shallow` exists.
    const shallow_marker = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{full.rev});
    defer testing.allocator.free(shallow_marker);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/.git/shallow", .data = shallow_marker });
    const truncated_dest = try std.fs.path.join(testing.allocator, &.{ root, "truncated" });
    defer testing.allocator.free(truncated_dest);
    const truncated = try snapshotLocal(testing.allocator, testing.io, source, truncated_dest, null, false, false);
    try testing.expectEqual(@as(i64, -1), truncated.rev_count);
    const allowed_dest = try std.fs.path.join(testing.allocator, &.{ root, "allowed" });
    defer testing.allocator.free(allowed_dest);
    const allowed = try snapshotLocal(testing.allocator, testing.io, source, allowed_dest, null, false, true);
    try testing.expectEqual(@as(i64, 0), allowed.rev_count);
}
