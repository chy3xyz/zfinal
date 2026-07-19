const std = @import("std");
const io_instance = @import("../io_instance.zig");
const Plugin = @import("plugin.zig").Plugin;

/// Length-prefixed mesh frame: magic "ZFP2" | ver | type | len(u32 BE) | payload
pub const FrameType = enum(u8) {
    data = 0,
    peer_announce = 1,
    ping = 2,
    pong = 3,
};

pub const Peer = struct {
    host: []const u8,
    port: u16,
};

pub const InboxMessage = struct {
    from: []const u8,
    data: []const u8,

    pub fn deinit(self: *InboxMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.from);
        allocator.free(self.data);
    }
};

/// TCP mesh P2P: explicit peers + broadcast + inbox.
/// Discovery is gossip via `peer_announce` frames (no UDP multicast required).
pub const P2pPlugin = struct {
    allocator: std.mem.Allocator,
    port: u16,
    node_id: []const u8,
    peers: std.ArrayList(Peer) = .empty,
    inbox: std.ArrayList(InboxMessage) = .empty,
    /// Spin mutex — server runs on `std.Thread`; `std.Io.Mutex` futex is unsafe across
    /// threads under `std.testing.io`.
    mutex: std.atomic.Mutex = .unlocked,
    running: std.atomic.Value(bool) = .init(false),
    listen_ready: std.atomic.Value(bool) = .init(false),
    server_thread: ?std.Thread = null,

    const magic = "ZFP2";
    const version: u8 = 1;

    pub fn init(allocator: std.mem.Allocator, port: u16) !P2pPlugin {
        const id = try std.fmt.allocPrint(allocator, "node-{d}", .{port});
        return .{
            .allocator = allocator,
            .port = port,
            .node_id = id,
        };
    }

    pub fn initWithId(allocator: std.mem.Allocator, port: u16, node_id: []const u8) !P2pPlugin {
        return .{
            .allocator = allocator,
            .port = port,
            .node_id = try allocator.dupe(u8, node_id),
        };
    }

    fn lock(self: *P2pPlugin) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *P2pPlugin) void {
        self.mutex.unlock();
    }

    pub fn deinit(self: *P2pPlugin) void {
        self.stopListening() catch {};
        self.lock();
        for (self.peers.items) |p| self.allocator.free(p.host);
        self.peers.deinit(self.allocator);
        for (self.inbox.items) |*m| m.deinit(self.allocator);
        self.inbox.deinit(self.allocator);
        self.unlock();
        self.allocator.free(self.node_id);
    }

    pub fn plugin(self: *P2pPlugin) Plugin {
        return .{
            .name = "P2P",
            .vtable = &.{ .start = start, .stop = stop },
            .context = self,
        };
    }

    fn start(ctx: *anyopaque) !void {
        const self: *P2pPlugin = @ptrCast(@alignCast(ctx));
        try self.startListening();
    }

    fn stop(ctx: *anyopaque) !void {
        const self: *P2pPlugin = @ptrCast(@alignCast(ctx));
        try self.stopListening();
    }

    pub fn startListening(self: *P2pPlugin) !void {
        if (self.running.swap(true, .monotonic)) return;
        self.listen_ready.store(false, .monotonic);
        self.server_thread = try std.Thread.spawn(.{}, serverLoop, .{self});
        // Wait until accept socket is bound (or thread exits).
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            if (self.listen_ready.load(.monotonic)) return;
            if (!self.running.load(.monotonic)) return error.ListenFailed;
            std.Io.sleep(io_instance.io, std.Io.Duration.fromMilliseconds(5), .real) catch {};
        }
        return error.ListenTimeout;
    }

    pub fn stopListening(self: *P2pPlugin) !void {
        if (!self.running.swap(false, .monotonic)) return;
        bumpLocalhost(self.port);
        if (self.server_thread) |t| {
            t.join();
            self.server_thread = null;
        }
    }

    fn bumpLocalhost(port: u16) void {
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return;
        const stream = addr.connect(io_instance.io, .{ .mode = .stream }) catch return;
        stream.close(io_instance.io);
    }

    pub fn addPeer(self: *P2pPlugin, host: []const u8, port: u16) !void {
        self.lock();
        defer self.unlock();
        for (self.peers.items) |p| {
            if (p.port == port and std.mem.eql(u8, p.host, host)) return;
        }
        try self.peers.append(self.allocator, .{
            .host = try self.allocator.dupe(u8, host),
            .port = port,
        });
    }

    pub fn peerCount(self: *P2pPlugin) usize {
        self.lock();
        defer self.unlock();
        return self.peers.items.len;
    }

    pub fn inboxLen(self: *P2pPlugin) usize {
        self.lock();
        defer self.unlock();
        return self.inbox.items.len;
    }

    pub fn takeInbox(self: *P2pPlugin) ![]InboxMessage {
        self.lock();
        defer self.unlock();
        return try self.inbox.toOwnedSlice(self.allocator);
    }

    /// Encode a frame into `out` (caller owns).
    pub fn encodeFrame(allocator: std.mem.Allocator, typ: FrameType, payload: []const u8) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, magic);
        try buf.append(allocator, version);
        try buf.append(allocator, @intFromEnum(typ));
        var len_be: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_be, @intCast(payload.len), .big);
        try buf.appendSlice(allocator, &len_be);
        try buf.appendSlice(allocator, payload);
        return try buf.toOwnedSlice(allocator);
    }

    /// Decode one frame from `data`. Returns payload slice into `data` and bytes consumed.
    pub fn decodeFrame(data: []const u8) !struct { typ: FrameType, payload: []const u8, consumed: usize } {
        if (data.len < 10) return error.NeedMoreData;
        if (!std.mem.eql(u8, data[0..4], magic)) return error.BadMagic;
        if (data[4] != version) return error.BadVersion;
        const typ: FrameType = @enumFromInt(data[5]);
        const len = std.mem.readInt(u32, data[6..10], .big);
        if (data.len < 10 + len) return error.NeedMoreData;
        return .{ .typ = typ, .payload = data[10 .. 10 + len], .consumed = 10 + len };
    }

    fn sendFrame(stream: std.Io.net.Stream, typ: FrameType, payload: []const u8, allocator: std.mem.Allocator) !void {
        const frame = try encodeFrame(allocator, typ, payload);
        defer allocator.free(frame);
        var wbuf: [4096]u8 = undefined;
        var writer = stream.writer(io_instance.io, &wbuf);
        try writer.interface.writeAll(frame);
        try writer.interface.flush();
    }

    pub fn sendTo(self: *P2pPlugin, host: []const u8, port: u16, data: []const u8) !void {
        const addr = try std.Io.net.IpAddress.parseIp4(host, port);
        const stream = try addr.connect(io_instance.io, .{ .mode = .stream });
        defer stream.close(io_instance.io);
        try sendFrame(stream, .data, data, self.allocator);
    }

    fn snapshotPeers(self: *P2pPlugin) ![]Peer {
        self.lock();
        defer self.unlock();
        const snapshot = try self.allocator.alloc(Peer, self.peers.items.len);
        errdefer self.allocator.free(snapshot);
        var filled: usize = 0;
        errdefer {
            for (snapshot[0..filled]) |p| self.allocator.free(p.host);
        }
        for (self.peers.items, 0..) |p, i| {
            snapshot[i] = .{ .host = try self.allocator.dupe(u8, p.host), .port = p.port };
            filled = i + 1;
        }
        return snapshot;
    }

    fn freePeerSnapshot(self: *P2pPlugin, snapshot: []Peer) void {
        for (snapshot) |p| self.allocator.free(p.host);
        self.allocator.free(snapshot);
    }

    pub fn broadcast(self: *P2pPlugin, message: []const u8) !void {
        const snapshot = try self.snapshotPeers();
        defer self.freePeerSnapshot(snapshot);

        var last_err: ?anyerror = null;
        for (snapshot) |p| {
            self.sendTo(p.host, p.port, message) catch |err| {
                last_err = err;
            };
        }
        if (last_err) |e| return e;
    }

    /// Announce this node's listen port to all peers (gossip bootstrap).
    pub fn announce(self: *P2pPlugin) !void {
        const payload = try std.fmt.allocPrint(self.allocator, "{s}|{d}", .{ self.node_id, self.port });
        defer self.allocator.free(payload);

        const snapshot = try self.snapshotPeers();
        defer self.freePeerSnapshot(snapshot);

        for (snapshot) |p| {
            const addr = std.Io.net.IpAddress.parseIp4(p.host, p.port) catch continue;
            const stream = addr.connect(io_instance.io, .{ .mode = .stream }) catch continue;
            defer stream.close(io_instance.io);
            sendFrame(stream, .peer_announce, payload, self.allocator) catch {};
        }
    }

    fn serverLoop(self: *P2pPlugin) void {
        defer self.running.store(false, .monotonic);
        const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch return;
        var server = address.listen(io_instance.io, .{ .reuse_address = true }) catch return;
        defer server.deinit(io_instance.io);
        self.listen_ready.store(true, .release);

        while (self.running.load(.monotonic)) {
            const conn = server.accept(io_instance.io) catch {
                if (!self.running.load(.monotonic)) break;
                continue;
            };
            defer conn.close(io_instance.io);
            if (!self.running.load(.monotonic)) break;
            self.handleConn(conn) catch {};
        }
    }

    fn handleConn(self: *P2pPlugin, conn: std.Io.net.Stream) !void {
        var rbuf: [8192]u8 = undefined;
        var reader = conn.reader(io_instance.io, &rbuf);
        var accum: std.ArrayList(u8) = .empty;
        defer accum.deinit(self.allocator);

        while (true) {
            var chunk: [4096]u8 = undefined;
            const n = reader.interface.readSliceShort(chunk[0..]) catch break;
            if (n == 0) break;
            try accum.appendSlice(self.allocator, chunk[0..n]);
            while (true) {
                const decoded = decodeFrame(accum.items) catch |err| switch (err) {
                    error.NeedMoreData => break,
                    else => return err,
                };
                try self.dispatch(decoded.typ, decoded.payload);
                const consumed = decoded.consumed;
                std.mem.copyForwards(u8, accum.items[0 .. accum.items.len - consumed], accum.items[consumed..]);
                accum.shrinkRetainingCapacity(accum.items.len - consumed);
            }
        }
    }

    fn dispatch(self: *P2pPlugin, typ: FrameType, payload: []const u8) !void {
        switch (typ) {
            .data => {
                self.lock();
                defer self.unlock();
                try self.inbox.append(self.allocator, .{
                    .from = try self.allocator.dupe(u8, "peer"),
                    .data = try self.allocator.dupe(u8, payload),
                });
            },
            .peer_announce => {
                // payload: "node-id|port"
                if (std.mem.lastIndexOfScalar(u8, payload, '|')) |bar| {
                    const port = std.fmt.parseInt(u16, payload[bar + 1 ..], 10) catch return;
                    try self.addPeer("127.0.0.1", port);
                }
            },
            .ping => {},
            .pong => {},
        }
    }
};

test "p2p: frame encode/decode roundtrip" {
    const a = std.testing.allocator;
    const frame = try P2pPlugin.encodeFrame(a, .data, "hello");
    defer a.free(frame);
    const d = try P2pPlugin.decodeFrame(frame);
    try std.testing.expect(d.typ == .data);
    try std.testing.expectEqualStrings("hello", d.payload);
    try std.testing.expectEqual(frame.len, d.consumed);
}

test "p2p: decode NeedMoreData" {
    try std.testing.expectError(error.NeedMoreData, P2pPlugin.decodeFrame("ZFP"));
}

test "p2p: mesh broadcast localhost" {
    const a = std.testing.allocator;
    var a_node = try P2pPlugin.initWithId(a, 19001, "A");
    defer a_node.deinit();
    var b_node = try P2pPlugin.initWithId(a, 19002, "B");
    defer b_node.deinit();

    try a_node.startListening();
    defer a_node.stopListening() catch {};
    try b_node.startListening();
    defer b_node.stopListening() catch {};

    try a_node.addPeer("127.0.0.1", 19002);
    try a_node.broadcast("ping-from-a");

    var waited: usize = 0;
    while (b_node.inboxLen() == 0 and waited < 50) : (waited += 1) {
        std.Io.sleep(io_instance.io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
    }

    try std.testing.expect(b_node.inboxLen() >= 1);
    const msgs = try b_node.takeInbox();
    defer {
        for (msgs) |*m| m.deinit(a);
        a.free(msgs);
    }
    try std.testing.expectEqualStrings("ping-from-a", msgs[0].data);
}

test "p2p: peer_announce gossip adds peer" {
    const a = std.testing.allocator;
    var a_node = try P2pPlugin.initWithId(a, 19011, "A");
    defer a_node.deinit();
    var b_node = try P2pPlugin.initWithId(a, 19012, "B");
    defer b_node.deinit();

    try a_node.startListening();
    defer a_node.stopListening() catch {};
    try b_node.startListening();
    defer b_node.stopListening() catch {};

    try a_node.addPeer("127.0.0.1", 19012);
    try a_node.announce();

    var waited: usize = 0;
    while (b_node.peerCount() == 0 and waited < 50) : (waited += 1) {
        std.Io.sleep(io_instance.io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
    }
    try std.testing.expect(b_node.peerCount() >= 1);
}
