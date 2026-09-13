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

    /// Owned, immutable copy of a session, returned by `getSession`.
    ///
    /// Replaces the previous `getSession() ?*Session` API, which handed out a
    /// pointer into the hash map **after releasing the lock** — a concurrent
    /// `destroySession()` could free it mid-use (use-after-free). The snapshot
    /// is deep-copied under the lock, so it stays valid for as long as the
    /// caller holds it.
    pub const Snapshot = struct {
        id: []u8,
        data: std.StringHashMap([]u8),
        created_at: i64,
        last_accessed: i64,

        /// Caller must call this before the snapshot goes out of scope.
        pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            var iter = self.data.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            self.data.deinit();
        }

        /// Borrowed view into the snapshot; valid until `deinit`.
        pub fn get(self: *const Snapshot, key: []const u8) ?[]const u8 {
            return self.data.get(key);
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
        self.* = undefined;
    }

    /// Create a new session with a cryptographically secure unique ID.
    ///
    /// Returns a **caller-owned** id: free it with the store's allocator. (It is
    /// a separate allocation from the map key, which the store frees on
    /// `destroySession`/`deinit`.) The previous version returned the map-key
    /// slice itself, so destroying the session left callers with a dangling id.
    pub fn createSession(self: *SessionStore) ![]const u8 {
        try self.mutex.lock(io_instance.io);
        defer self.mutex.unlock(io_instance.io);

        // Generate secure random session ID (32 bytes hex = 64 chars).
        // Encoded manually: `std.fmt.fmtSliceHexLower` no longer exists in
        // Zig 0.17-dev.19xx (this module never compiled, so it went unnoticed).
        var random_bytes: [32]u8 = undefined;
        io_instance.io.random(&random_bytes);
        const hex = "0123456789abcdef";
        var hex_buf: [64]u8 = undefined;
        for (random_bytes, 0..) |byte, i| {
            hex_buf[i * 2] = hex[byte >> 4];
            hex_buf[i * 2 + 1] = hex[byte & 0x0f];
        }
        const session_id = hex_buf[0..];

        const key_copy = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(key_copy);
        const ret = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(ret);
        const now = std.Io.Timestamp.now(io_instance.io, .real).toSeconds();

        const session = Session{
            .id = key_copy,
            .data = std.StringHashMap([]const u8).init(self.allocator),
            .created_at = now,
            .last_accessed = now,
        };

        try self.sessions.put(key_copy, session);
        return ret;
    }

    /// Get an owned, thread-safe snapshot of a session, refreshing
    /// `last_accessed`. Returns null when there is no such session.
    ///
    /// The copy is made while the store mutex is held, so the result is valid
    /// even if the session is destroyed concurrently. Caller owns the snapshot
    /// and must `deinit` it.
    pub fn getSession(self: *SessionStore, session_id: []const u8) !?Snapshot {
        try self.mutex.lock(io_instance.io);
        defer self.mutex.unlock(io_instance.io);

        const session = self.sessions.getPtr(session_id) orelse return null;
        session.last_accessed = std.Io.Timestamp.now(io_instance.io, .real).toSeconds();

        const id_copy = try self.allocator.dupe(u8, session.id);
        errdefer self.allocator.free(id_copy);

        var data_copy = std.StringHashMap([]u8).init(self.allocator);
        errdefer {
            var it = data_copy.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            data_copy.deinit();
        }

        var it = session.data.iterator();
        while (it.next()) |entry| {
            const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(key_copy);
            const value_copy = try self.allocator.dupe(u8, entry.value_ptr.*);
            try data_copy.put(key_copy, value_copy);
        }

        return Snapshot{
            .id = id_copy,
            .data = data_copy,
            .created_at = session.created_at,
            .last_accessed = session.last_accessed,
        };
    }

    /// Set attribute in session (thread-safe)
    pub fn setAttr(self: *SessionStore, session_id: []const u8, key: []const u8, value: []const u8) !void {
        try self.mutex.lock(io_instance.io);
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
        try self.mutex.lock(io_instance.io);
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
        self.mutex.lockUncancelable(io_instance.io);
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
        self.mutex.lockUncancelable(io_instance.io);
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

    // Create session (the returned id is caller-owned)
    const session_id = try store.createSession();
    defer allocator.free(session_id);
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
    try std.testing.expect((try store.getSession(session_id)) == null);
}

test "session: snapshot outlives destroySession (no use-after-free)" {
    const allocator = std.testing.allocator;
    var store = SessionStore.init(allocator);
    defer store.deinit();

    const id = try store.createSession();
    defer allocator.free(id);
    try store.setAttr(id, "user", "john");
    try store.setAttr(id, "role", "admin");

    var snapshot = (try store.getSession(id)).?;
    defer snapshot.deinit(allocator);
    try std.testing.expectEqualStrings("john", snapshot.get("user").?);
    try std.testing.expectEqualStrings(id, snapshot.id);

    // Destroying the stored session must not invalidate the snapshot — this is
    // exactly the window the old borrowed `?*Session` API left open.
    store.destroySession(id);
    try std.testing.expectEqualStrings("john", snapshot.get("user").?);
    try std.testing.expectEqualStrings("admin", snapshot.get("role").?);
    try std.testing.expectEqualStrings(id, snapshot.id);
    try std.testing.expect((try store.getSession(id)) == null);
}

test "session: concurrent getSession while destroySession runs is race-free" {
    const allocator = std.testing.allocator;
    var store = SessionStore.init(allocator);
    defer store.deinit();

    const n = 8;
    var ids: [n][]const u8 = undefined;
    for (&ids) |*id| id.* = try store.createSession();
    defer for (ids) |id| allocator.free(id);

    var stop = std.atomic.Value(bool).init(false);
    const Ctx = struct {
        store: *SessionStore,
        ids: []const []const u8,
        stop: *std.atomic.Value(bool),
        fn reader(self: *@This()) void {
            while (!self.stop.load(.acquire)) {
                for (self.ids) |id| {
                    if (self.store.getSession(id) catch null) |snapshot| {
                        var s = snapshot;
                        s.deinit(std.testing.allocator);
                    }
                }
            }
        }
    };
    var ctx = Ctx{ .store = &store, .ids = &ids, .stop = &stop };

    var threads: [3]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Ctx.reader, .{&ctx});

    // Writer: destroy every session while the readers hammer getSession. Under
    // the old API the readers would dereference freed memory here.
    for (ids) |id| store.destroySession(id);
    stop.store(true, .release);
    for (&threads) |*t| t.join();
}
