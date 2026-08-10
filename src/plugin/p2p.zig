const std = @import("std");
const io_instance = @import("../io_instance.zig");
const sockread = @import("../core/sockread.zig");
const Plugin = @import("plugin.zig").Plugin;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// Length-prefixed mesh frame: magic "ZFP2" | ver | type | len(u32 BE) | payload
/// When `hmac_key` is set, payload is `HMAC-SHA256(typ||plain) || plain` (32 + N).
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
    /// Bind / announce host (default `127.0.0.1`). Set to LAN/public IP for multi-host.
    bind_host: []const u8,
    node_id: []const u8,
    peers: std.ArrayList(Peer) = .empty,
    inbox: std.ArrayList(InboxMessage) = .empty,
    /// Drop inbound frames larger than this (DoS guard).
    max_frame_len: u32 = 1 * 1024 * 1024,
    /// Cap inbox size; oldest dropped when full.
    max_inbox: usize = 1024,
    /// Optional shared secret for frame HMAC (duped via `setHmacKey`).
    hmac_key: ?[]const u8 = null,
    /// Spin mutex — server runs on `std.Thread`; `std.Io.Mutex` futex is unsafe across
    /// threads under `std.testing.io`.
    mutex: std.atomic.Mutex = .unlocked,
    running: std.atomic.Value(bool) = .init(false),
    listen_ready: std.atomic.Value(bool) = .init(false),
    listen_failed: std.atomic.Value(bool) = .init(false),
    server_thread: ?std.Thread = null,

    const magic = "ZFP2";
    const version: u8 = 1;
    const hmac_len: usize = HmacSha256.mac_length;

    pub fn init(allocator: std.mem.Allocator, port: u16) !P2pPlugin {
        const id = try std.fmt.allocPrint(allocator, "node-{d}", .{port});
        return .{
            .allocator = allocator,
            .port = port,
            .bind_host = try allocator.dupe(u8, "127.0.0.1"),
            .node_id = id,
        };
    }

    pub fn initWithId(allocator: std.mem.Allocator, port: u16, node_id: []const u8) !P2pPlugin {
        return .{
            .allocator = allocator,
            .port = port,
            .bind_host = try allocator.dupe(u8, "127.0.0.1"),
            .node_id = try allocator.dupe(u8, node_id),
        };
    }

    /// Optional: set after init, before `startListening`. Takes ownership of `host` duped copy.
    pub fn setBindHost(self: *P2pPlugin, host: []const u8) !void {
        const owned = try self.allocator.dupe(u8, host);
        self.allocator.free(self.bind_host);
        self.bind_host = owned;
    }

    /// Shared HMAC key for all mesh frames. Pass empty to clear. Caller retains `key`.
    pub fn setHmacKey(self: *P2pPlugin, key: []const u8) !void {
        if (self.hmac_key) |old| self.allocator.free(old);
        self.hmac_key = if (key.len == 0) null else try self.allocator.dupe(u8, key);
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
        self.allocator.free(self.bind_host);
        if (self.hmac_key) |k| self.allocator.free(k);
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
        self.listen_failed.store(false, .monotonic);
        self.server_thread = try std.Thread.spawn(.{}, serverLoop, .{self});
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            if (self.listen_ready.load(.monotonic)) return;
            if (self.listen_failed.load(.monotonic) or !self.running.load(.monotonic)) return error.ListenFailed;
            std.Io.sleep(io_instance.io, std.Io.Duration.fromMilliseconds(5), .real) catch {};
        }
        return error.ListenTimeout;
    }

    pub fn stopListening(self: *P2pPlugin) !void {
        if (!self.running.swap(false, .monotonic)) return;
        bumpHost(self.bind_host, self.port);
        if (self.server_thread) |t| {
            t.join();
            self.server_thread = null;
        }
    }

    fn bumpHost(host: []const u8, port: u16) void {
        const addr = std.Io.net.IpAddress.parseIp4(host, port) catch return;
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
        try buf.append(allocator, @backingInt(typ));
        var len_be: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_be, @intCast(payload.len), .big);
        try buf.appendSlice(allocator, &len_be);
        try buf.appendSlice(allocator, payload);
        return try buf.toOwnedSlice(allocator);
    }

    pub const FrameDecoded = struct {
        typ: FrameType,
        payload: []const u8,
        consumed: usize,
    };

    /// Decode one frame from `data`. Returns payload slice into `data` and bytes consumed.
    pub fn decodeFrame(data: []const u8) !FrameDecoded {
        return decodeFrameLimited(data, std.math.maxInt(u32));
    }

    pub fn decodeFrameLimited(data: []const u8, max_len: u32) !FrameDecoded {
        if (data.len < 10) return error.NeedMoreData;
        if (!std.mem.eql(u8, data[0..4], magic)) return error.BadMagic;
        if (data[4] != version) return error.BadVersion;
        const typ: FrameType = @fromBackingInt(@intCast(data[5]));
        const len = std.mem.readInt(u32, data[6..10], .big);
        if (len > max_len) return error.FrameTooLarge;
        if (data.len < 10 + len) return error.NeedMoreData;
        return .{ .typ = typ, .payload = data[10 .. 10 + len], .consumed = 10 + len };
    }

    fn sealPayload(self: *P2pPlugin, typ: FrameType, plain: []const u8) ![]u8 {
        const key = self.hmac_key orelse return try self.allocator.dupe(u8, plain);
        const out = try self.allocator.alloc(u8, hmac_len + plain.len);
        errdefer self.allocator.free(out);
        var mac: [hmac_len]u8 = undefined;
        var h = HmacSha256.init(key);
        const typ_b = [_]u8{@backingInt(typ)};
        h.update(&typ_b);
        h.update(plain);
        h.final(&mac);
        @memcpy(out[0..hmac_len], &mac);
        @memcpy(out[hmac_len..], plain);
        return out;
    }

    fn openPayload(self: *P2pPlugin, typ: FrameType, sealed: []const u8) ![]const u8 {
        const key = self.hmac_key orelse return sealed;
        if (sealed.len < hmac_len) return error.BadHmac;
        var expected: [hmac_len]u8 = undefined;
        var h = HmacSha256.init(key);
        const typ_b = [_]u8{@backingInt(typ)};
        h.update(&typ_b);
        h.update(sealed[hmac_len..]);
        h.final(&expected);
        if (!std.crypto.timing_safe.eql([hmac_len]u8, sealed[0..hmac_len].*, expected)) {
            return error.BadHmac;
        }
        return sealed[hmac_len..];
    }

    fn sendFrame(self: *P2pPlugin, stream: std.Io.net.Stream, typ: FrameType, payload: []const u8) !void {
        const sealed = try self.sealPayload(typ, payload);
        defer self.allocator.free(sealed);
        const frame = try encodeFrame(self.allocator, typ, sealed);
        defer self.allocator.free(frame);
        var wbuf: [4096]u8 = undefined;
        var writer = stream.writer(io_instance.io, &wbuf);
        try writer.interface.writeAll(frame);
        try writer.interface.flush();
    }

    /// Data wire format: `node_id\0payload` so inbox `from` is attributable.
    pub fn sendTo(self: *P2pPlugin, host: []const u8, port: u16, data: []const u8) !void {
        const wire = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ self.node_id, data });
        defer self.allocator.free(wire);
        const addr = try std.Io.net.IpAddress.parseIp4(host, port);
        const stream = try addr.connect(io_instance.io, .{ .mode = .stream });
        defer stream.close(io_instance.io);
        try self.sendFrame(stream, .data, wire);
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

    /// Announce this node's listen host+port to all peers (gossip bootstrap).
    /// Payload: `node_id|host|port` (legacy `node_id|port` still accepted on receive).
    pub fn announce(self: *P2pPlugin) !void {
        const payload = try std.fmt.allocPrint(self.allocator, "{s}|{s}|{d}", .{ self.node_id, self.bind_host, self.port });
        defer self.allocator.free(payload);

        const snapshot = try self.snapshotPeers();
        defer self.freePeerSnapshot(snapshot);

        for (snapshot) |p| {
            const addr = std.Io.net.IpAddress.parseIp4(p.host, p.port) catch continue;
            const stream = addr.connect(io_instance.io, .{ .mode = .stream }) catch continue;
            defer stream.close(io_instance.io);
            self.sendFrame(stream, .peer_announce, payload) catch {};
        }
    }

    /// Probe peers with ping frames (best-effort).
    pub fn heartbeat(self: *P2pPlugin) void {
        const snapshot = self.snapshotPeers() catch return;
        defer self.freePeerSnapshot(snapshot);
        for (snapshot) |p| {
            const addr = std.Io.net.IpAddress.parseIp4(p.host, p.port) catch continue;
            const stream = addr.connect(io_instance.io, .{ .mode = .stream }) catch continue;
            defer stream.close(io_instance.io);
            self.sendFrame(stream, .ping, self.node_id) catch {};
        }
    }

    fn serverLoop(self: *P2pPlugin) void {
        defer self.running.store(false, .monotonic);
        const address = std.Io.net.IpAddress.parseIp4(self.bind_host, self.port) catch {
            self.listen_failed.store(true, .release);
            return;
        };
        var server = address.listen(io_instance.io, .{ .reuse_address = true }) catch {
            self.listen_failed.store(true, .release);
            return;
        };
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
        var accum: std.ArrayList(u8) = .empty;
        defer accum.deinit(self.allocator);

        while (true) {
            var chunk: [4096]u8 = undefined;
            const n = sockread.readSome(conn, &chunk) catch break;
            if (n == 0) break;
            try accum.appendSlice(self.allocator, chunk[0..n]);
            while (true) {
                const decoded = decodeFrameLimited(accum.items, self.max_frame_len) catch |err| switch (err) {
                    error.NeedMoreData => break,
                    else => return err,
                };
                try self.dispatch(conn, decoded.typ, decoded.payload);
                const consumed = decoded.consumed;
                std.mem.copyForwards(u8, accum.items[0 .. accum.items.len - consumed], accum.items[consumed..]);
                accum.shrinkRetainingCapacity(accum.items.len - consumed);
            }
        }
    }

    fn pushInbox(self: *P2pPlugin, from: []const u8, data: []const u8) !void {
        self.lock();
        defer self.unlock();
        while (self.inbox.items.len >= self.max_inbox) {
            var old = self.inbox.orderedRemove(0);
            old.deinit(self.allocator);
        }
        try self.inbox.append(self.allocator, .{
            .from = try self.allocator.dupe(u8, from),
            .data = try self.allocator.dupe(u8, data),
        });
    }

    fn dispatch(self: *P2pPlugin, conn: std.Io.net.Stream, typ: FrameType, sealed: []const u8) !void {
        const payload = try self.openPayload(typ, sealed);
        switch (typ) {
            .data => {
                var from: []const u8 = "peer";
                var data = payload;
                if (std.mem.indexOfScalar(u8, payload, 0)) |z| {
                    from = payload[0..z];
                    data = payload[z + 1 ..];
                }
                try self.pushInbox(from, data);
            },
            .peer_announce => {
                // "node|port" or "node|host|port"
                var parts: [3][]const u8 = undefined;
                var n: usize = 0;
                var it = std.mem.splitScalar(u8, payload, '|');
                while (it.next()) |p| {
                    if (n >= parts.len) break;
                    parts[n] = p;
                    n += 1;
                }
                if (n == 2) {
                    const port = std.fmt.parseInt(u16, parts[1], 10) catch return;
                    try self.addPeer(self.bind_host, port);
                } else if (n >= 3) {
                    const port = std.fmt.parseInt(u16, parts[2], 10) catch return;
                    try self.addPeer(parts[1], port);
                }
            },
            .ping => {
                self.sendFrame(conn, .pong, payload) catch {};
            },
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
    try std.testing.expectEqualStrings("A", msgs[0].from);
}

test "p2p: FrameTooLarge" {
    var hdr: [10]u8 = undefined;
    @memcpy(hdr[0..4], "ZFP2");
    hdr[4] = 1;
    hdr[5] = 0;
    std.mem.writeInt(u32, hdr[6..10], 100, .big);
    try std.testing.expectError(error.FrameTooLarge, P2pPlugin.decodeFrameLimited(&hdr, 10));
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

test "p2p: HMAC accepts matching key and rejects mismatch" {
    const a = std.testing.allocator;
    var a_node = try P2pPlugin.initWithId(a, 19021, "A");
    defer a_node.deinit();
    var b_node = try P2pPlugin.initWithId(a, 19022, "B");
    defer b_node.deinit();
    try a_node.setHmacKey("shared-secret");
    try b_node.setHmacKey("shared-secret");

    try a_node.startListening();
    defer a_node.stopListening() catch {};
    try b_node.startListening();
    defer b_node.stopListening() catch {};

    try a_node.addPeer("127.0.0.1", 19022);
    try a_node.broadcast("hmac-ok");
    var waited: usize = 0;
    while (b_node.inboxLen() == 0 and waited < 50) : (waited += 1) {
        std.Io.sleep(io_instance.io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
    }
    try std.testing.expect(b_node.inboxLen() >= 1);

    var c_node = try P2pPlugin.initWithId(a, 19023, "C");
    defer c_node.deinit();
    try c_node.setHmacKey("wrong-secret");
    try c_node.startListening();
    defer c_node.stopListening() catch {};
    try a_node.addPeer("127.0.0.1", 19023);
    try a_node.broadcast("should-drop");
    waited = 0;
    while (waited < 20) : (waited += 1) {
        std.Io.sleep(io_instance.io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
    }
    try std.testing.expectEqual(@as(usize, 0), c_node.inboxLen());
}
