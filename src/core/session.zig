const std = @import("std");
const io_instance = @import("../io_instance.zig");

/// Simple in-memory session store
pub const SessionStore = struct {
    sessions: std.StringHashMap(Session),
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex,

    pub const Session = struct {
        id: []const u8,
        data: std.StringHashMap([]const u8),
        created_at: i64,
        last_accessed: i64,

        pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            var iter = self.data.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            self.data.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator) SessionStore {
        return SessionStore{
            .sessions = std.StringHashMap(Session).init(allocator),
            .allocator = allocator,
            .mutex = std.Io.Mutex.init,
        };
    }

    pub fn deinit(self: *SessionStore) void {
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            var session = entry.value_ptr;
            session.deinit(self.allocator);
        }
        self.sessions.deinit();
    }

    /// Create a new session with a cryptographically secure unique ID
    pub fn createSession(self: *SessionStore) ![]const u8 {
        self.mutex.lock(io_instance.io) catch {};
        defer self.mutex.unlock(io_instance.io);

        // Generate secure random session ID (32 bytes hex = 64 chars)
        var random_bytes: [32]u8 = undefined;
        io_instance.io.random(&random_bytes);

        var buf: [64]u8 = undefined;
        const session_id = try std.fmt.bufPrint(&buf, "{s}", .{std.fmt.fmtSliceHexLower(&random_bytes)});

        const id_copy = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(id_copy);
        const now = std.Io.Timestamp.now(io_instance.io, .real).toSeconds();

        const session = Session{
            .id = id_copy,
            .data = std.StringHashMap([]const u8).init(self.allocator),
            .created_at = now,
            .last_accessed = now,
        };

        try self.sessions.put(id_copy, session);
        return id_copy;
    }

    /// Get session by ID
    pub fn getSession(self: *SessionStore, session_id: []const u8) ?*Session {
        self.mutex.lock(io_instance.io) catch {};
        defer self.mutex.unlock(io_instance.io);

        if (self.sessions.getPtr(session_id)) |session| {
            session.last_accessed = std.Io.Timestamp.now(io_instance.io, .real).toSeconds();
            return session;
        }
        return null;
    }

    /// Set attribute in session (thread-safe)
    pub fn setAttr(self: *SessionStore, session_id: []const u8, key: []const u8, value: []const u8) !void {
        self.mutex.lock(io_instance.io) catch {};
        defer self.mutex.unlock(io_instance.io);

        if (self.sessions.getPtr(session_id)) |session| {
            const key_copy = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_copy);
            const value_copy = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(value_copy);

            // Free old value if exists
            if (session.data.fetchRemove(key)) |old| {
                self.allocator.free(old.key);
                self.allocator.free(old.value);
            }

            try session.data.put(key_copy, value_copy);
            session.last_accessed = std.Io.Timestamp.now(io_instance.io, .real).toSeconds();
        }
    }

    /// Get attribute from session (thread-safe).
    /// Returns an owned copy — caller must free with store.allocator.
    pub fn getAttr(self: *SessionStore, session_id: []const u8, key: []const u8) !?[]const u8 {
        self.mutex.lock(io_instance.io) catch {};
        defer self.mutex.unlock(io_instance.io);

        if (self.sessions.getPtr(session_id)) |session| {
            session.last_accessed = std.Io.Timestamp.now(io_instance.io, .real).toSeconds();
            if (session.data.get(key)) |value| {
                return try self.allocator.dupe(u8, value);
            }
        }
        return null;
    }

    /// Remove attribute from session (thread-safe)
    pub fn removeAttr(self: *SessionStore, session_id: []const u8, key: []const u8) void {
        self.mutex.lock(io_instance.io) catch {};
        defer self.mutex.unlock(io_instance.io);

        if (self.sessions.getPtr(session_id)) |session| {
            session.last_accessed = std.Io.Timestamp.now(io_instance.io, .real).toSeconds();
            if (session.data.fetchRemove(key)) |old| {
                self.allocator.free(old.key);
                self.allocator.free(old.value);
            }
        }
    }

    /// Destroy session
    pub fn destroySession(self: *SessionStore, session_id: []const u8) void {
        self.mutex.lock(io_instance.io) catch {};
        defer self.mutex.unlock(io_instance.io);

        if (self.sessions.fetchRemove(session_id)) |entry| {
            var session = entry.value;
            session.deinit(self.allocator);
        }
    }
};

test "session store basic operations" {
    const allocator = std.testing.allocator;

    var store = SessionStore.init(allocator);
    defer store.deinit();

    // Create session
    const session_id = try store.createSession();
    try std.testing.expect(session_id.len > 0);

    // Set and get attribute
    try store.setAttr(session_id, "user", "john");
    const value = try store.getAttr(session_id, "user");
    defer if (value) |v| allocator.free(v);
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("john", value.?);

    // Remove attribute
    store.removeAttr(session_id, "user");
    const removed = try store.getAttr(session_id, "user");
    defer if (removed) |v| allocator.free(v);
    try std.testing.expect(removed == null);

    // Destroy session
    store.destroySession(session_id);
    try std.testing.expect(store.getSession(session_id) == null);
}
