const std = @import("std");

/// Simple in-memory session store
pub const SessionStore = struct {
    sessions: std.StringHashMap(Session),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

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
            .mutex = .{},
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

    /// Create a new session with a unique ID
    pub fn createSession(self: *SessionStore) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Generate simple session ID (UUID-like)
        var buf: [36]u8 = undefined;
        var prng = std.rand.DefaultPrng.init(@intCast(std.time.timestamp()));
        const random = prng.random();

        const session_id = try std.fmt.bufPrint(&buf, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}", .{
            random.int(u32),
            random.int(u16),
            random.int(u16),
            random.int(u16),
            random.int(u48),
        });

        const id_copy = try self.allocator.dupe(u8, session_id);
        const now = std.time.timestamp();

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
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.getPtr(session_id)) |session| {
            session.last_accessed = std.time.timestamp();
            return session;
        }
        return null;
    }

    /// Set attribute in session
    pub fn setAttr(self: *SessionStore, session_id: []const u8, key: []const u8, value: []const u8) !void {
        if (self.getSession(session_id)) |session| {
            const key_copy = try self.allocator.dupe(u8, key);
            const value_copy = try self.allocator.dupe(u8, value);

            // Free old value if exists
            if (session.data.fetchRemove(key)) |old| {
                self.allocator.free(old.key);
                self.allocator.free(old.value);
            }

            try session.data.put(key_copy, value_copy);
        }
    }

    /// Get attribute from session
    pub fn getAttr(self: *SessionStore, session_id: []const u8, key: []const u8) ?[]const u8 {
        if (self.getSession(session_id)) |session| {
            return session.data.get(key);
        }
        return null;
    }

    /// Remove attribute from session
    pub fn removeAttr(self: *SessionStore, session_id: []const u8, key: []const u8) void {
        if (self.getSession(session_id)) |session| {
            if (session.data.fetchRemove(key)) |old| {
                self.allocator.free(old.key);
                self.allocator.free(old.value);
            }
        }
    }

    /// Destroy session
    pub fn destroySession(self: *SessionStore, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

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
    const value = store.getAttr(session_id, "user");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("john", value.?);

    // Remove attribute
    store.removeAttr(session_id, "user");
    try std.testing.expect(store.getAttr(session_id, "user") == null);

    // Destroy session
    store.destroySession(session_id);
    try std.testing.expect(store.getSession(session_id) == null);
}
