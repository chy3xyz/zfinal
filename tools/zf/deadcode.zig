//! Re-export [zdeadcode](https://github.com/chy3xyz/zdeadcode) for `zf check --deadcode`.
//! Sources live in `./zdeadcode/` (MIT © chy3xyz). See `zdeadcode/UPSTREAM.md`.
const std = @import("std");

pub const analyze = @import("zdeadcode/analyze.zig");
pub const scanner = @import("zdeadcode/scanner.zig");
pub const report = @import("zdeadcode/report.zig");

pub const RunOpts = struct {
    paths: []const []const u8 = &.{},
    binary: bool = false,
    include_pub: bool = false,
    no_tests: bool = false,
    no_members: bool = false,
    no_files: bool = false,
    no_gitignore: bool = false,
    json: bool = false,
    verbose: bool = false,
};

pub const RunResult = struct {
    text: []u8,
    finding_count: usize,
    unused_file_count: usize,
    summary: analyze.Summary,

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }

    pub fn hasFindings(self: *const RunResult) bool {
        return self.finding_count > 0 or self.unused_file_count > 0;
    }
};

/// Scan + analyze + format. Temporary state lives in an arena; only `text` is
/// allocated with `allocator`.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: RunOpts,
) !RunResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];

    const files = try scanner.scan(arena, io, cwd, opts.paths, .{
        .gitignore = !opts.no_gitignore,
    });
    if (files.len == 0) return error.NoZigFiles;

    var sources: std.ArrayList(analyze.File) = .empty;
    var root_paths: std.ArrayList([]const u8) = .empty;

    for (files) |f| {
        const content = std.Io.Dir.cwd().readFileAlloc(io, f.path, arena, .unlimited) catch continue;
        const source: [:0]u8 = try arena.allocSentinel(u8, content.len, 0);
        @memcpy(source[0..content.len], content);
        try sources.append(arena, .{
            .path = f.path,
            .display_path = f.display,
            .source = source,
        });
    }

    for (opts.paths) |p| {
        const abs = std.fs.path.resolve(arena, &.{ cwd, p }) catch continue;
        try root_paths.append(arena, abs);
    }

    var result = try analyze.analyze(arena, sources.items, .{
        .include_pub = opts.include_pub,
        .no_tests = opts.no_tests,
        .no_members = opts.no_members,
        .binary = opts.binary,
        .no_files = opts.no_files,
        .root_file_paths = root_paths.items,
    });
    defer result.deinit();

    const text_tmp = if (opts.json)
        try report.formatJson(arena, &result, sources.items)
    else
        try report.formatHuman(arena, &result, sources.items, .{
            .json = false,
            .verbose = opts.verbose,
        });

    return .{
        .text = try allocator.dupe(u8, text_tmp),
        .finding_count = result.findings.len,
        .unused_file_count = result.unused_files.len,
        .summary = result.summary,
    };
}
