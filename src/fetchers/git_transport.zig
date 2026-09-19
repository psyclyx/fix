//! ziggit adapter for evaluator-owned Git sources.

const std = @import("std");
const clock = @import("base").clock;
const ziggit = @import("ziggit");

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
    /// A `known_hosts` file that decides ssh host key trust on its own. A
    /// host missing from it is refused, never silently trusted; see
    /// `hostKeyVerifier`.
    known_hosts: ?[]const u8 = null,
    /// The ssh agent socket, usually `$SSH_AUTH_SOCK`. ziggit reads no
    /// environment of its own, so the caller supplies this. Null offers no
    /// agent credential, and an `ssh://` fetch that needs one then fails.
    ssh_auth_sock: ?[]const u8 = null,
};
pub const Result = struct {
    rev: [40]u8,
    rev_count: i64,
    last_modified: i64,
    last_modified_date: [14]u8,
};

/// Every fault this file reports through `materialize` or `snapshotLocal`,
/// once whatever ziggit or the filesystem actually raised has been
/// translated by `mapError`. `fetch_cache.zig`'s `retryable()` reads these
/// names directly, so their meaning ("retry" vs. "do not retry") must stay
/// exactly what it already is.
const MaterializeError = error{
    FetchTransient,
    FetchGitFailed,
    FetchGitRevisionNotFound,
    FetchTlsVerificationFailed,
    /// Nix git revs are sha1 only. A sha256 repository is refused here
    /// rather than having its id silently truncated into `Result.rev`.
    FetchGitUnsupportedHash,
    /// The server answered that the repository is not there. Every ziggit
    /// transport reports this from the daemon's own `ERR` line or its HTTP
    /// equivalent, so it names a missing repository rather than a fault
    /// that another attempt could clear.
    FetchGitNotFound,
} || std.mem.Allocator.Error;

/// The checkout strategy every write into a worktree uses, for the top
/// level commit and for every submodule alike: overwrite a tracked path
/// that already exists, create whatever is missing, and remove anything
/// found that the tree being checked out does not name.
const checkout_strategy = ziggit.Strategy{
    .force = true,
    .recreate_missing = true,
    .remove_untracked = true,
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
    var diag: ?ziggit.Diagnostic = null;
    defer if (diag) |*d| d.deinit(allocator);

    var source_dir = std.Io.Dir.cwd().openDir(io, repository_path, .{ .iterate = true }) catch
        return error.FetchGitFailed;
    defer source_dir.close(io);

    var repo = discoverRepository(allocator, io, source_dir, &diag) catch |err| return mapError(err);
    defer repo.deinit();

    const target = resolveObject(allocator, &repo, rev, null, &diag) catch |err| return err;
    const commit_oid = ziggit.peel(allocator, &repo, target, .commit) catch |err| return mapError(err);
    const commit_info = try readCommitInfo(allocator, &repo, commit_oid, &diag);

    try std.Io.Dir.cwd().createDirPath(io, destination);
    if (rev != null) {
        try exportCommit(allocator, io, &repo, commit_info.tree, repository_path, destination, submodules, &diag);
    } else {
        try copyTrackedWorktree(allocator, io, &repo, repository_path, destination, submodules);
    }
    return resultFromCommit(allocator, &repo, commit_oid, commit_info.committer_when, shallow, &diag);
}

/// Clone or refresh a worktree, resolve the requested commit, then cleanly
/// check it out. `refresh=false` still opens and validates the existing cache.
pub fn materialize(
    allocator: std.mem.Allocator,
    io: std.Io,
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
    var diag: ?ziggit.Diagnostic = null;
    defer if (diag) |*d| d.deinit(allocator);

    try std.Io.Dir.cwd().createDirPath(io, path);
    var work_dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer work_dir.close(io);

    var created = false;
    var repo = openRepositoryAt(allocator, io, work_dir, &diag) catch |err| switch (err) {
        error.NotARepository => blk: {
            ziggit.Repository.init(allocator, io, work_dir, .{}) catch |init_err| return mapError(init_err);
            created = true;
            break :blk openRepositoryAt(allocator, io, work_dir, &diag) catch |reopen_err| return mapError(reopen_err);
        },
        else => return mapError(err),
    };
    defer repo.deinit();

    var reporter_value: Reporter = undefined;
    if (options.reporter) |value| reporter_value = value;
    const progress: ?ziggit.Progress = if (options.reporter != null)
        .{ .ctx = &reporter_value, .onBytes = onFetchProgress }
    else
        null;
    var credential_context = CredentialContext{
        .credentials = options.credentials,
        .origin_url = url,
        .ssh_auth_sock = options.ssh_auth_sock,
    };
    const transport_options = ziggit.TransportOptions{
        .credentials = credentialCallback,
        .credentials_ctx = &credential_context,
        .progress = progress,
        .ca_cert_file = options.ca_file,
        .connect_timeout_ms = timeoutMilliseconds(options.connect_timeout_seconds),
        .stall_timeout_s = options.stalled_timeout_seconds,
        .proxy_url = options.proxy_url,
    };
    const ssh_options = ziggit.Ssh.SshOptions{
        .known_hosts_path = options.known_hosts,
        .verifier = hostKeyVerifier,
    };

    const refspec_text = try fetchRefspec(allocator, rev, ref_name, all_refs);
    defer allocator.free(refspec_text);

    if (created) {
        repo.createRemote("origin", url, refspec_text) catch |err| return mapError(err);
        try fetchTargeted(allocator, io, &repo, url, refspec_text, rev, ref_name, all_refs, shallow, transport_options, ssh_options, &diag);
    } else if (refresh) {
        try fetchTargeted(allocator, io, &repo, url, refspec_text, rev, ref_name, all_refs, shallow, transport_options, ssh_options, &diag);
    }

    const target = resolveObject(allocator, &repo, rev, ref_name, &diag) catch |err| return err;
    const commit_oid = ziggit.peel(allocator, &repo, target, .commit) catch |err| return mapError(err);
    const commit_info = try readCommitInfo(allocator, &repo, commit_oid, &diag);

    ziggit.checkoutTree(allocator, io, &repo.odb, work_dir, commit_info.tree, checkout_strategy, &diag) catch |err| return mapError(err);
    // No reflog message: a fresh clone's repository carries no configured
    // committer (see `Repository.OpenOptions.committer`), and asking for one
    // anyway would turn every materialize into `error.NoCommitterIdentity`.
    repo.refs.setHeadDetached(commit_oid, null, &diag) catch |err| return mapError(err);
    if (submodules) {
        try updateSubmodules(allocator, io, &repo, work_dir, transport_options, ssh_options, &diag);
    }

    return resultFromCommit(allocator, &repo, commit_oid, commit_info.committer_when, shallow, &diag);
}

/// Opens the repository that contains `dir`, walking up as `git` does.
/// `snapshotLocal` wants this: a caller can name any directory inside a
/// checkout, exactly as libgit2's `GIT_REPOSITORY_OPEN_CROSS_FS` allowed.
fn discoverRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    diag: ?*?ziggit.Diagnostic,
) !ziggit.Repository {
    return openLayout(allocator, io, dir, .{}, diag);
}

/// Opens the repository at exactly `dir` and never one above it.
///
/// `materialize` owns the directory it clones into, so an upward walk is
/// unsafe here: an empty cache directory that happens to sit inside an
/// unrelated checkout would resolve to that checkout, and this file would
/// then fetch into it and check out over it with `remove_untracked`. A
/// `git_dir_override` of ".git" is git's own shape for a work tree, so
/// `discover` opens that one directory, treats `dir` as the work tree, and
/// reports `NotARepository` when it is absent.
fn openRepositoryAt(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    diag: ?*?ziggit.Diagnostic,
) !ziggit.Repository {
    return openLayout(allocator, io, dir, .{ .git_dir_override = ".git" }, diag);
}

/// `discover` hands back a `Layout` that `Repository.open` takes ownership
/// of only on success; on any other error this still owns it and must free
/// it itself, hence the `errdefer`.
fn openLayout(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    options: ziggit.DiscoverOptions,
    diag: ?*?ziggit.Diagnostic,
) !ziggit.Repository {
    var layout = try ziggit.discover(allocator, io, dir, options, diag);
    errdefer layout.deinit(io);
    return ziggit.Repository.open(allocator, io, layout, .{}, diag);
}

const CommitInfo = struct {
    tree: ziggit.Oid,
    committer_when: i64,
};

/// Allocation budget for reading one commit object whole. Real commits are
/// a few kilobytes even with a long message; this matches the ceiling
/// `ziggit-fetch` and `ziggit-submodule` already use for the same object
/// kind, so a hostile or corrupt commit past it is refused, not read.
const max_commit_object_len: usize = 1 << 20;

/// Reads and parses the commit at `oid`, then copies out only the two
/// fields this file needs. `Commit.parse` borrows its message and identity
/// fields from the byte buffer it was given; extracting `tree` (a plain
/// value) and `committer.when` (a plain `i64`) before that buffer is freed
/// is what keeps this file free of a use-after-free on those borrowed
/// fields, since nothing here ever touches them again.
fn readCommitInfo(
    allocator: std.mem.Allocator,
    repo: *ziggit.Repository,
    oid: ziggit.Oid,
    diag: ?*?ziggit.Diagnostic,
) !CommitInfo {
    const bytes = repo.odb.readAlloc(allocator, oid, max_commit_object_len, diag) catch |err| return mapError(err);
    defer allocator.free(bytes);
    var commit = ziggit.Commit.parse(allocator, repo.format, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CorruptCommit => return error.FetchGitFailed,
    };
    defer commit.deinit(allocator);
    return .{ .tree = commit.tree, .committer_when = commit.committer.when };
}

fn resultFromCommit(
    allocator: std.mem.Allocator,
    repo: *ziggit.Repository,
    commit_oid: ziggit.Oid,
    committer_when: i64,
    shallow: bool,
    diag: ?*?ziggit.Diagnostic,
) !Result {
    if (repo.format != .sha1) return error.FetchGitUnsupportedHash;

    var result: Result = undefined;
    var hex_buf: [ziggit.Oid.max_formatted_length]u8 = undefined;
    const hex = commit_oid.toHex(&hex_buf);
    @memcpy(&result.rev, hex[0..result.rev.len]);

    // No walking a truncated history: a requested shallow fetch counts as 0
    // (Nix's value for it), and an unrequested-shallow repository reports
    // the -1 sentinel so `revCount` can fail lazily on use, as in Nix.
    result.rev_count = if (shallow)
        0
    else if (repo.isShallow(diag) catch |err| return mapError(err))
        -1
    else
        @intCast(ziggit.countReachable(allocator, repo, commit_oid) catch |err| return mapError(err));
    result.last_modified = committer_when;
    result.last_modified_date = clock.formatUtc(result.last_modified);
    return result;
}

fn copyTrackedWorktree(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *ziggit.Repository,
    source_root: []const u8,
    destination_root: []const u8,
    submodules: bool,
) !void {
    // `git_dir`, never `common_dir`: a linked worktree keeps its own index
    // beside its own HEAD, while `common_dir` points back at the main
    // repository. Reading the shared one would snapshot the wrong checkout.
    var index = ziggit.WorktreeIndex.open(allocator, io, repo.layout.git_dir, repo.format) catch |err| switch (err) {
        // No index yet is an ordinary state for a repository nothing has
        // been staged in, not a fault: there is simply nothing tracked to
        // copy.
        error.IndexNotFound => return,
        else => return mapError(err),
    };
    defer index.deinit();

    for (index.entries) |entry| {
        // Conflict stages live outside the normal stage; only the normal
        // stage describes the tracked worktree snapshot.
        if (entry.stage != .merged) continue;
        const source = try std.fs.path.join(allocator, &.{ source_root, entry.path });
        defer allocator.free(source);
        const destination = try std.fs.path.join(allocator, &.{ destination_root, entry.path });
        defer allocator.free(destination);

        if (entry.mode == .gitlink) {
            try std.Io.Dir.cwd().createDirPath(io, destination);
            if (submodules) {
                var child_dir = std.Io.Dir.cwd().openDir(io, source, .{ .iterate = true }) catch continue;
                defer child_dir.close(io);
                var child = discoverRepository(allocator, io, child_dir, null) catch continue;
                defer child.deinit();
                try copyTrackedWorktree(allocator, io, &child, source, destination, true);
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
    repo: *ziggit.Repository,
    tree_oid: ziggit.Oid,
    source_root: []const u8,
    destination_root: []const u8,
    submodules: bool,
    diag: ?*?ziggit.Diagnostic,
) anyerror!void {
    try exportTree(allocator, io, repo, tree_oid, source_root, destination_root, "", submodules, diag);
}

/// Allocation budget for reading one tree object whole. Matches
/// `ziggit-checkout`'s own ceiling: a hostile or corrupt tree past this is
/// refused, not read.
const max_tree_object_len: usize = 1 << 20;

/// Allocation budget for one symlink target. `std.fs.max_path_bytes` is the
/// longest a real filesystem path can be; a blob this large named by a
/// symlink entry is refused, not read.
const max_symlink_target_len: usize = std.fs.max_path_bytes;

fn exportTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *ziggit.Repository,
    tree_oid: ziggit.Oid,
    source_root: []const u8,
    destination_root: []const u8,
    prefix: []const u8,
    submodules: bool,
    diag: ?*?ziggit.Diagnostic,
) anyerror!void {
    const bytes = repo.odb.readAlloc(allocator, tree_oid, max_tree_object_len, diag) catch |err| return mapError(err);
    defer allocator.free(bytes);
    var tree = ziggit.Tree.parse(allocator, repo.format, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CorruptTree => return error.FetchGitFailed,
    };
    defer tree.deinit(allocator);

    for (tree.entries) |entry| {
        const relative = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ prefix, entry.name });
        defer allocator.free(relative);
        const destination = try std.fs.path.join(allocator, &.{ destination_root, relative });
        defer allocator.free(destination);

        switch (entry.mode) {
            .tree => {
                try std.Io.Dir.cwd().createDirPath(io, destination);
                try exportTree(allocator, io, repo, entry.oid, source_root, destination_root, relative, submodules, diag);
            },
            .blob, .blob_executable => {
                const parent = std.fs.path.dirname(destination) orelse destination_root;
                try std.Io.Dir.cwd().createDirPath(io, parent);
                var file = std.Io.Dir.cwd().createFile(io, destination, .{
                    .permissions = if (entry.mode == .blob_executable) .executable_file else .default_file,
                }) catch return error.FetchGitFailed;
                defer file.close(io);
                // Streamed straight from the object database into the
                // destination file: the libgit2 version read a whole blob
                // into memory first, which spiked on a large file.
                var write_buffer: [8192]u8 = undefined;
                var writer = file.writer(io, &write_buffer);
                _ = repo.odb.read(entry.oid, &writer.interface, diag) catch |err| return mapError(err);
                writer.end() catch return error.FetchGitFailed;
            },
            .symlink => {
                const parent = std.fs.path.dirname(destination) orelse destination_root;
                try std.Io.Dir.cwd().createDirPath(io, parent);
                const link_target = repo.odb.readAlloc(allocator, entry.oid, max_symlink_target_len, diag) catch |err| return mapError(err);
                defer allocator.free(link_target);
                try std.Io.Dir.symLinkAbsolute(io, link_target, destination, .{});
            },
            .gitlink => {
                try std.Io.Dir.cwd().createDirPath(io, destination);
                if (submodules) {
                    const source = try std.fs.path.join(allocator, &.{ source_root, relative });
                    defer allocator.free(source);
                    var child_dir = std.Io.Dir.cwd().openDir(io, source, .{ .iterate = true }) catch continue;
                    defer child_dir.close(io);
                    var child = discoverRepository(allocator, io, child_dir, null) catch continue;
                    defer child.deinit();
                    const child_info = readCommitInfo(allocator, &child, entry.oid, null) catch continue;
                    try exportCommit(allocator, io, &child, child_info.tree, source, destination, true, diag);
                }
            },
        }
    }
}

/// Fetch `refspec`, falling back for a pinned rev to the requested ref (or
/// HEAD): a rev fetches by OID where the transport negotiates it, as Nix
/// does, but some transports only accept advertised ref names, and the ref's
/// history must then contain the rev. `shallow` applies to the fallback
/// fetch too.
fn fetchTargeted(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *ziggit.Repository,
    url: []const u8,
    refspec_text: []const u8,
    rev: ?[]const u8,
    ref_name: ?[]const u8,
    all_refs: bool,
    shallow: bool,
    transport_options: ziggit.TransportOptions,
    ssh_options: ziggit.Ssh.SshOptions,
    diag: ?*?ziggit.Diagnostic,
) !void {
    attemptFetch(allocator, io, repo, url, refspec_text, shallow, transport_options, ssh_options, diag) catch |err| {
        if (rev == null or all_refs) return err;
        const fallback_text = try fetchRefspec(allocator, null, ref_name, false);
        defer allocator.free(fallback_text);
        try attemptFetch(allocator, io, repo, url, fallback_text, shallow, transport_options, ssh_options, diag);
    };
}

/// One fetch attempt for a single refspec. `ziggit.fetch` can return
/// successfully while one matched refspec still failed to update its local
/// ref, so a clean return is not enough; `result.firstFailure()` is checked
/// too, and either kind of failure is reported through `mapError`.
fn attemptFetch(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *ziggit.Repository,
    url: []const u8,
    refspec_text: []const u8,
    shallow: bool,
    transport_options: ziggit.TransportOptions,
    ssh_options: ziggit.Ssh.SshOptions,
    diag: ?*?ziggit.Diagnostic,
) !void {
    var refspec = try ziggit.Refspec.parse(allocator, refspec_text);
    defer refspec.deinit(allocator);
    const refspecs = [_]ziggit.Refspec{refspec};

    var result = ziggit.fetch(allocator, io, repo, url, .{
        .refspecs = &refspecs,
        .depth = if (shallow) 1 else null,
        .transport = transport_options,
        .ssh = ssh_options,
    }, diag) catch |err| return mapError(err);
    defer result.deinit(allocator);

    if (result.firstFailure()) |failure| {
        return switch (failure.outcome) {
            // `firstFailure` never returns one of these; it only ever
            // returns the first entry that is NOT one of them.
            .updated, .up_to_date => unreachable,
            .rejected_non_fast_forward, .symbolic_ref_unchanged => error.FetchGitFailed,
            .failed => |err| mapError(err),
        };
    }
}

fn updateSubmodules(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *ziggit.Repository,
    worktree: std.Io.Dir,
    transport_options: ziggit.TransportOptions,
    ssh_options: ziggit.Ssh.SshOptions,
    diag: ?*?ziggit.Diagnostic,
) !void {
    // Matches the refspec a plain `git submodule update` fetches with: a
    // submodule's own pinned commit can be anywhere in its branch history,
    // not only on whichever branch happened to be current when it was
    // added.
    var refspec = try ziggit.Refspec.parse(allocator, "+refs/heads/*:refs/remotes/origin/*");
    defer refspec.deinit(allocator);
    const refspecs = [_]ziggit.Refspec{refspec};

    ziggit.updateAll(allocator, io, repo, worktree, .{
        .recursive = true,
        .fetch = .{
            .refspecs = &refspecs,
            .transport = transport_options,
            .ssh = ssh_options,
        },
        .strategy = checkout_strategy,
    }, diag) catch |err| return mapError(err);
}

/// The single refspec Nix fetches: everything under `allRefs`, the pinned rev
/// itself, or the one requested ref (a plain name means a branch, as in Nix);
/// the remote's HEAD when nothing is requested.
fn fetchRefspec(allocator: std.mem.Allocator, rev: ?[]const u8, ref_name: ?[]const u8, all_refs: bool) ![]u8 {
    if (all_refs) return allocator.dupe(u8, "+refs/*:refs/*");
    if (rev) |value| return std.fmt.allocPrint(allocator, "+{s}:refs/remotes/origin/pinned", .{value});
    if (ref_name) |value| {
        if (std.mem.startsWith(u8, value, "refs/"))
            return std.fmt.allocPrint(allocator, "+{s}:{s}", .{ value, value });
        return std.fmt.allocPrint(allocator, "+refs/heads/{s}:refs/remotes/origin/{s}", .{ value, value });
    }
    return allocator.dupe(u8, "+HEAD:refs/remotes/origin/HEAD");
}

fn resolveObject(
    allocator: std.mem.Allocator,
    repo: *ziggit.Repository,
    rev: ?[]const u8,
    ref_name: ?[]const u8,
    diag: ?*?ziggit.Diagnostic,
) !ziggit.Oid {
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
        if (ziggit.resolve(allocator, repo, candidate.?, diag)) |oid| {
            return oid;
        } else |err| switch (err) {
            // The allocator itself is failing, not merely a mismatch on
            // this one candidate; propagate rather than silently trying
            // the next one.
            error.OutOfMemory => return err,
            else => {},
        }
    }
    return error.FetchGitRevisionNotFound;
}

const CredentialContext = struct {
    credentials: ?Credentials,
    origin_url: []const u8,
    ssh_auth_sock: ?[]const u8,
};

/// Credentials go only to the origin they were issued for: a fetch that
/// gets redirected, or that dials a different host than the caller asked
/// for, never sees this file's username and password.
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

fn credentialCallback(ctx: ?*anyopaque, url: []const u8, host: []const u8, allowed: ziggit.AllowedTypes) ?ziggit.Credential {
    _ = host;
    const context: *const CredentialContext = @ptrCast(@alignCast(ctx orelse return null));
    if (allowed.basic) {
        if (context.credentials) |cred| {
            if (sameAuthority(context.origin_url, url)) {
                return .{ .basic = .{ .username = cred.username, .password = cred.password } };
            }
        }
    }
    if (allowed.ssh_agent) {
        if (context.ssh_auth_sock) |socket_path| {
            return .{ .ssh_agent = .{ .socket_path = socket_path } };
        }
    }
    return null;
}

/// `Ssh.SshOptions.verifier` has no default and no bypass: a caller must
/// decide host key trust. This always refuses, because trust here comes
/// entirely from `SshOptions.known_hosts_path`, which decides on its own
/// and never reaches this verifier on a match; a host absent from
/// `known_hosts` is refused rather than silently trusted.
fn hostKeyVerifier(ctx: ?*anyopaque, host: []const u8, key_type: []const u8, key: []const u8) bool {
    _ = ctx;
    _ = host;
    _ = key_type;
    _ = key;
    return false;
}

fn onFetchProgress(ctx: ?*anyopaque, received: u64, total: ?u64) void {
    const reporter: *const Reporter = @ptrCast(@alignCast(ctx orelse return));
    reporter.report(reporter.ctx, received, total orelse 0);
}

fn timeoutMilliseconds(seconds: u32) u32 {
    return seconds *| 1000;
}

/// Translates a fault from anywhere in ziggit, or a raw std.Io/std.fs
/// fault, into one of this file's own names. `fetch_cache.zig`'s
/// `retryable()` reads those names directly, so `FetchGitRevisionNotFound`,
/// `FetchGitNotFound` and `FetchTlsVerificationFailed` must keep meaning
/// "do not retry," and
/// `FetchTransient` must keep meaning "retry." Everything else becomes the
/// generic `FetchGitFailed`, mirroring how libgit2's own `git_error_last()`
/// gave this file one opaque class for almost every fault; ziggit gives
/// named faults instead, but not every one of them earns its own retry
/// policy.
fn mapError(err: anyerror) MaterializeError {
    if (err == error.OutOfMemory) return error.OutOfMemory;

    return switch (err) {
        error.NetworkFailed,
        error.Timeout,
        error.ConnectionLost,
        error.ServerBusy,
        error.AuthRequired,
        error.AuthFailed,
        error.NotFound,
        error.ProtocolError,
        error.UnsupportedProtocol,
        error.HostKeyRejected,
        error.UnsupportedKeyType,
        error.SshAgentUnavailable,
        error.NoUsableAgentKey,
        error.TlsVerificationFailed,
        => blk: {
            // `ziggit`'s front package does not re-export the transport
            // error set by name, only `isTransient`, which carries it as
            // its own parameter type; `@errorCast` here infers that type
            // from the call it feeds. Every tag matched above is one of
            // that set's own members (`OutOfMemory`, its other member, is
            // handled above), so the cast cannot fail.
            break :blk if (err == error.TlsVerificationFailed)
                error.FetchTlsVerificationFailed
            else if (err == error.NotFound)
                error.FetchGitNotFound
            else if (ziggit.isTransient(@errorCast(err)))
                error.FetchTransient
            else
                error.FetchGitFailed;
        },
        error.UnknownRevision, error.RefNotFound => error.FetchGitRevisionNotFound,
        else => error.FetchGitFailed,
    };
}

/// Who and when every fixture commit is written by. Fixed, not read from
/// the environment: an assertion comparing two revs must not depend on the
/// wall clock or on the machine's own git identity.
const test_committer = ziggit.Committer{ .name = "Fix Test", .email = "fix@example.invalid" };
const test_commit_when: i64 = 1_700_000_000;

/// Stages the worktree, writes a real `.git/index`, then commits the tree
/// that index describes and points the current branch at it.
///
/// The index is the reason this stages rather than writing a tree straight
/// from a directory walk: `snapshotLocal` with no rev reads `.git/index` to
/// decide what is tracked, so a fixture with no index exercises none of
/// that path.
fn createTestCommit(allocator: std.mem.Allocator, io: std.Io, repository_path: []const u8, message: []const u8) !void {
    var diag: ?ziggit.Diagnostic = null;
    defer if (diag) |*d| d.deinit(allocator);

    var dir = try std.Io.Dir.cwd().openDir(io, repository_path, .{ .iterate = true });
    defer dir.close(io);

    var repo = openRepositoryAt(allocator, io, dir, &diag) catch |err| switch (err) {
        error.NotARepository => blk: {
            try ziggit.Repository.init(allocator, io, dir, .{});
            break :blk try openRepositoryAt(allocator, io, dir, &diag);
        },
        else => return err,
    };
    defer repo.deinit();

    // `stageWorktree` skips `.git`, so the object database this writes into
    // is never itself staged even though it lives under the directory being
    // walked.
    var index = try ziggit.stageWorktree(allocator, io, dir, &repo.odb, repo.format);
    defer index.deinit();
    try ziggit.writeWorktreeIndex(index, io, repo.layout.git_dir, repo.format);
    const tree_oid = try ziggit.writeTreeFromIndex(allocator, &repo.odb, index, &diag);

    // An unborn branch (no commit yet) resolves HEAD as `error.RefNotFound`,
    // which is the first fixture commit, not a fault.
    const parent_oid: ?ziggit.Oid = repo.head(&diag) catch |err| switch (err) {
        error.RefNotFound => null,
        else => return err,
    };
    var parent_buf: [1]ziggit.Oid = undefined;
    const parents: []const ziggit.Oid = if (parent_oid) |p| blk: {
        parent_buf[0] = p;
        break :blk parent_buf[0..1];
    } else &.{};

    const identity = test_committer.at(test_commit_when);
    const commit: ziggit.Commit = .{
        .tree = tree_oid,
        .parents = parents,
        .author = identity,
        .committer = identity,
        .extra_headers = &.{},
        .message = message,
    };
    var commit_writer: std.Io.Writer.Allocating = .init(allocator);
    defer commit_writer.deinit();
    try commit.write(&commit_writer.writer);
    const commit_oid = try repo.odb.write(.commit, commit_writer.writer.buffered(), &diag);

    const branch = try repo.headBranch(&diag) orelse return error.DetachedHeadUnsupported;
    defer allocator.free(branch);
    const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch});
    defer allocator.free(ref_name);
    // No reflog message: this fixture repository carries no configured
    // committer either, for the same reason `materialize`'s own detached
    // HEAD write above carries none.
    try repo.refs.update(ref_name, commit_oid, parent_oid, null, &diag);
}

test "ziggit clone, refresh, checkout, and metadata" {
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

    try createTestCommit(testing.allocator, testing.io, source, "one");

    const first = try materialize(testing.allocator, testing.io, url, clone_path, null, null, false, false, false, true, .{});
    try testing.expectEqual(@as(i64, 1), first.rev_count);
    try testing.expect(first.last_modified > 0);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/file", .data = "two" });
    try createTestCommit(testing.allocator, testing.io, source, "two");
    const second = try materialize(testing.allocator, testing.io, url, clone_path, null, null, false, false, false, true, .{});
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

    try createTestCommit(testing.allocator, testing.io, source, "one");
    _ = try materialize(testing.allocator, testing.io, url, clone_path, null, null, false, false, false, true, .{});

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

    try createTestCommit(testing.allocator, testing.io, source, "one");

    var diag: ?ziggit.Diagnostic = null;
    defer if (diag) |*d| d.deinit(testing.allocator);
    var source_dir = try std.Io.Dir.cwd().openDir(testing.io, source, .{ .iterate = true });
    defer source_dir.close(testing.io);

    // Grow a second branch so fetch breadth is observable, then return HEAD
    // to the default branch before the fetches below run.
    const default_branch = blk: {
        var repo = try openRepositoryAt(testing.allocator, testing.io, source_dir, &diag);
        defer repo.deinit();
        const branch = try repo.headBranch(&diag) orelse return error.TestUnexpectedResult;
        const head_oid = try repo.head(&diag);
        try repo.refs.update("refs/heads/feature", head_oid, null, null, &diag);
        try repo.refs.setHead("refs/heads/feature", null, &diag);
        break :blk branch;
    };
    defer testing.allocator.free(default_branch);
    const default_ref_name = try std.fmt.allocPrint(testing.allocator, "refs/heads/{s}", .{default_branch});
    defer testing.allocator.free(default_ref_name);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/file", .data = "two" });
    try createTestCommit(testing.allocator, testing.io, source, "two");

    var feature_rev: [40]u8 = undefined;
    {
        var repo = try openRepositoryAt(testing.allocator, testing.io, source_dir, &diag);
        defer repo.deinit();
        const tip = try ziggit.resolve(testing.allocator, &repo, "refs/heads/feature", &diag);
        var hex_buf: [ziggit.Oid.max_formatted_length]u8 = undefined;
        const hex = tip.toHex(&hex_buf);
        @memcpy(&feature_rev, hex[0..feature_rev.len]);
        try repo.refs.setHead(default_ref_name, null, &diag);
    }

    const hasFeatureTip = struct {
        fn in(alloc: std.mem.Allocator, io: std.Io, clone_path: []const u8, spec: []const u8) !bool {
            var d: ?ziggit.Diagnostic = null;
            defer if (d) |*dd| dd.deinit(alloc);
            var clone_dir = try std.Io.Dir.cwd().openDir(io, clone_path, .{ .iterate = true });
            defer clone_dir.close(io);
            var repo = try openRepositoryAt(alloc, io, clone_dir, &d);
            defer repo.deinit();
            // Whether resolution actually succeeded, not whether the ref
            // merely exists: an absent ref and a corrupt one both mean
            // "the tip is not here."
            _ = ziggit.resolve(alloc, &repo, spec, &d) catch return false;
            return true;
        }
    }.in;

    const head_clone = try std.fs.path.join(testing.allocator, &.{ root, "head" });
    defer testing.allocator.free(head_clone);
    const head_only = try materialize(testing.allocator, testing.io, url, head_clone, null, null, false, false, false, true, .{});
    try testing.expectEqual(@as(i64, 1), head_only.rev_count);
    // The local transport copies the whole object store, so breadth shows in
    // the ref layout: a HEAD fetch must not track the other branch.
    try testing.expect(!try hasFeatureTip(testing.allocator, testing.io, head_clone, "refs/heads/feature"));
    try testing.expect(!try hasFeatureTip(testing.allocator, testing.io, head_clone, "refs/remotes/origin/feature"));

    const all_clone = try std.fs.path.join(testing.allocator, &.{ root, "all" });
    defer testing.allocator.free(all_clone);
    _ = try materialize(testing.allocator, testing.io, url, all_clone, null, null, false, true, false, true, .{});
    try testing.expect(try hasFeatureTip(testing.allocator, testing.io, all_clone, "refs/heads/feature"));

    const rev_clone = try std.fs.path.join(testing.allocator, &.{ root, "rev" });
    defer testing.allocator.free(rev_clone);
    const pinned = try materialize(testing.allocator, testing.io, url, rev_clone, &feature_rev, null, false, false, false, true, .{});
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

    try createTestCommit(testing.allocator, testing.io, source, "one");

    const full_dest = try std.fs.path.join(testing.allocator, &.{ root, "full" });
    defer testing.allocator.free(full_dest);
    const full = try snapshotLocal(testing.allocator, testing.io, source, full_dest, null, false, false);
    try testing.expectEqual(@as(i64, 1), full.rev_count);
    // Proves `copyTrackedWorktree` ran. Without this the whole test passes
    // against a snapshot that copied nothing, which it did while ziggit had
    // no index writer and the fixtures carried no `.git/index`.
    try expectSnapshotFile(testing.allocator, testing.io, full_dest, "file", "one");

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

/// Detaches `repository_path`'s HEAD onto whatever commit it names now, and
/// reports that commit's hex id.
fn detachTestHead(allocator: std.mem.Allocator, io: std.Io, repository_path: []const u8) ![40]u8 {
    var diag: ?ziggit.Diagnostic = null;
    defer if (diag) |*d| d.deinit(allocator);

    var dir = try std.Io.Dir.cwd().openDir(io, repository_path, .{ .iterate = true });
    defer dir.close(io);
    var repo = try openRepositoryAt(allocator, io, dir, &diag);
    defer repo.deinit();

    const oid = try repo.head(&diag);
    try repo.refs.setHeadDetached(oid, null, &diag);

    // Proves the detach landed. Without this the caller's test still passes
    // against a symbolic HEAD, which resolves to the same commit, and would
    // quietly stop covering the detached case it exists for.
    if (try repo.headBranch(&diag)) |branch| {
        allocator.free(branch);
        return error.TestHeadStillSymbolic;
    }

    var hex_buf: [ziggit.Oid.max_formatted_length]u8 = undefined;
    var rev: [40]u8 = undefined;
    @memcpy(&rev, (oid.toHex(&hex_buf))[0..rev.len]);
    return rev;
}

// A local source can sit on a detached HEAD: `git checkout v1.2.3` in a
// working copy leaves one, and a Nix source may point at such a directory.
// ziggit advertises that HEAD as a plain object id with no symref target,
// unlike the symbolic case, so this drives the same path a symbolic HEAD
// takes and asserts the clone lands on the commit HEAD actually names.
test "an unpinned fetch resolves a source whose HEAD is detached" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "source", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/file", .data = "one" });
    const source = try tmp.dir.realPathFileAlloc(testing.io, "source", testing.allocator);
    defer testing.allocator.free(source);
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const clone_path = try std.fs.path.join(testing.allocator, &.{ root, "clone" });
    defer testing.allocator.free(clone_path);
    const url = try std.fmt.allocPrint(testing.allocator, "file://{s}", .{source});
    defer testing.allocator.free(url);

    try createTestCommit(testing.allocator, testing.io, source, "one");
    const detached_rev = try detachTestHead(testing.allocator, testing.io, source);

    const result = try materialize(testing.allocator, testing.io, url, clone_path, null, null, false, false, false, true, .{});
    try testing.expectEqualStrings(&detached_rev, &result.rev);
    try testing.expectEqual(@as(i64, 1), result.rev_count);

    // The checkout really landed, not merely the metadata.
    var clone_dir = try std.Io.Dir.cwd().openDir(testing.io, clone_path, .{});
    defer clone_dir.close(testing.io);
    const contents = try clone_dir.readFileAlloc(testing.io, "file", testing.allocator, .limited(64));
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("one", contents);
}

/// Asserts `relative` inside a snapshot holds exactly `expected`.
fn expectSnapshotFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    snapshot_path: []const u8,
    relative: []const u8,
    expected: []const u8,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, snapshot_path, .{});
    defer dir.close(io);
    const contents = try dir.readFileAlloc(io, relative, allocator, .limited(4096));
    defer allocator.free(contents);
    try std.testing.expectEqualStrings(expected, contents);
}

// `snapshotLocal`'s own doc comment promises this and nothing tested it
// until ziggit shipped an index writer: an unpinned snapshot copies what
// the index tracks, at its current worktree content, so an uncommitted
// edit to a tracked file is kept and an untracked file is left out.
test "an unpinned snapshot keeps dirty tracked edits and excludes untracked files" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "source", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/tracked", .data = "committed" });
    const source = try tmp.dir.realPathFileAlloc(testing.io, "source", testing.allocator);
    defer testing.allocator.free(source);
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    try createTestCommit(testing.allocator, testing.io, source, "one");

    // Both written after the commit, so the index tracks `tracked` alone and
    // its recorded blob no longer matches what is on disk.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/tracked", .data = "dirty" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/untracked", .data = "ignore me" });

    const dest = try std.fs.path.join(testing.allocator, &.{ root, "snapshot" });
    defer testing.allocator.free(dest);
    _ = try snapshotLocal(testing.allocator, testing.io, source, dest, null, false, false);

    try expectSnapshotFile(testing.allocator, testing.io, dest, "tracked", "dirty");

    var dir = try std.Io.Dir.cwd().openDir(testing.io, dest, .{});
    defer dir.close(testing.io);
    try testing.expectError(error.FileNotFound, dir.statFile(testing.io, "untracked", .{}));
    // Repository metadata is never part of a snapshot.
    try testing.expectError(error.FileNotFound, dir.statFile(testing.io, ".git", .{}));
}
