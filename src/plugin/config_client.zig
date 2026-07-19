const std = @import("std");
const io_instance = @import("../io_instance.zig");

/// Config lookup from env vars and/or a flat JSON object file.
/// Values returned by `get` are borrowed from the client (or process env) —
/// do not free them. `getOwned` returns a dupe the caller must free.
pub const ConfigClient = struct {
    allocator: std.mem.Allocator,
    source: ConfigSource = .env,
    /// Absolute or relative path to a JSON object file (for `.file` source).
    file_path: ?[]const u8 = null,
    file_values: std.StringHashMap([]const u8) = undefined,
    file_loaded: bool = false,

    pub const ConfigSource = enum { file, env, env_then_file };

    pub fn init(allocator: std.mem.Allocator) ConfigClient {
        return .{
            .allocator = allocator,
            .file_values = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ConfigClient) void {
        var it = self.file_values.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.file_values.deinit();
        if (self.file_path) |p| self.allocator.free(p);
    }

    pub fn setFilePath(self: *ConfigClient, path: []const u8) !void {
        if (self.file_path) |p| self.allocator.free(p);
        self.file_path = try self.allocator.dupe(u8, path);
        self.file_loaded = false;
    }

    pub fn loadFile(self: *ConfigClient) !void {
        const path = self.file_path orelse return error.NoFilePath;
        const file = try std.Io.Dir.cwd().openFile(io_instance.io, path, .{});
        defer file.close(io_instance.io);

        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(self.allocator);
        var rbuf: [4096]u8 = undefined;
        var rdr = file.reader(io_instance.io, &rbuf);
        while (true) {
            const n = rdr.interface.readSliceShort(rbuf[0..]) catch break;
            if (n == 0) break;
            try content.appendSlice(self.allocator, rbuf[0..n]);
            if (n < rbuf.len) break;
        }

        // Clear previous
        var old = self.file_values.iterator();
        while (old.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.file_values.clearRetainingCapacity();

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content.items, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidConfigJson;
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const val = switch (entry.value_ptr.*) {
                .string => |s| try self.allocator.dupe(u8, s),
                .integer => |i| try std.fmt.allocPrint(self.allocator, "{d}", .{i}),
                .float => |f| try std.fmt.allocPrint(self.allocator, "{d}", .{f}),
                .bool => |b| try self.allocator.dupe(u8, if (b) "true" else "false"),
                .null => try self.allocator.dupe(u8, ""),
                else => continue,
            };
            errdefer self.allocator.free(val);
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            try self.file_values.put(key, val);
        }
        self.file_loaded = true;
    }

    pub fn get(self: *ConfigClient, key: []const u8) !?[]const u8 {
        switch (self.source) {
            .env => return getenvBorrow(key),
            .file => {
                if (!self.file_loaded) try self.loadFile();
                return self.file_values.get(key);
            },
            .env_then_file => {
                if (getenvBorrow(key)) |v| return v;
                if (!self.file_loaded) try self.loadFile();
                return self.file_values.get(key);
            },
        }
    }

    pub fn getOwned(self: *ConfigClient, key: []const u8) !?[]u8 {
        const v = try self.get(key) orelse return null;
        return try self.allocator.dupe(u8, v);
    }

    /// Insert a value into the in-memory file map (useful for tests).
    pub fn putFileValue(self: *ConfigClient, key: []const u8, value: []const u8) !void {
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);
        const v = try self.allocator.dupe(u8, value);
        if (self.file_values.fetchRemove(k)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        try self.file_values.put(k, v);
        self.file_loaded = true;
    }
};

fn getenvBorrow(key: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (key.len >= buf.len) return null;
    @memcpy(buf[0..key.len], key);
    buf[key.len] = 0;
    const cstr: [*:0]const u8 = @ptrCast(&buf);
    const raw = std.c.getenv(cstr) orelse return null;
    return std.mem.span(raw);
}

test "config client: file map lookup" {
    const a = std.testing.allocator;
    var c = ConfigClient.init(a);
    defer c.deinit();
    c.source = .file;
    try c.putFileValue("db.host", "localhost");
    const v = try c.get("db.host");
    try std.testing.expectEqualStrings("localhost", v.?);
}
