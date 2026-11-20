//! NATS protocol client (default: localhost:4222) — zero third-party deps.
//!
//! Ported from zigmodu `messaging/Nats.zig`. Implements CONNECT, PUB, SUB,
//! UNSUB, MSG, PING/PONG, +OK/-ERR over TCP via `std.Io`.
//! Prefer the façade `QueueNatsClient` (`plugin/queue_nats.zig`) for app code.
//!
//! NATS 线上是字节流协议，有两个后果必须记住：
//!
//! 1. 一帧可能被拆到多次读里 —— 客户端自带接收缓冲区 `rx`，帧没收全就留着
//!    等下一次读，半帧处丢数据的事不能发生。
//! 2. 服务端会先把 MSG 发回来、**再**回 PONG —— 所以 `ping()` 必须扫到真正的
//!    PONG，途中遇到的 MSG 照常派发，否则订阅到的消息会被 ping 吃掉。

const std = @import("std");
const builtin = @import("builtin");
const sockread = @import("../core/sockread.zig");

fn nowMillis(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

pub const NatsConfig = struct {
    /// 主机名或 IP 字面量。主机名走 DNS 解析（默认 "localhost"）。
    url: []const u8 = "localhost",
    port: u16 = 4222,
    token: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    name: []const u8 = "zfinal-nats",
    ping_interval_ms: u64 = 30_000,
    max_reconnect_attempts: usize = 10,
};

/// 解析出来的连接端点。`owned` 为 true 时 `host` 由调用方释放。
pub const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    owned: bool,
};

/// 解析 `nats://host:port` / `tcp://host:port` / `host:port` / `host`。
/// 也接受 `nats://user:pass@host:port`（userinfo 只用来定位 host）。
pub fn parseUrl(allocator: std.mem.Allocator, url: []const u8) !ParsedUrl {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "nats://")) rest = rest["nats://".len..];
    if (std.mem.startsWith(u8, rest, "tcp://")) rest = rest["tcp://".len..];
    // 去掉路径
    if (std.mem.indexOfScalar(u8, rest, '/')) |i| rest = rest[0..i];
    // 去掉 userinfo
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |i| rest = rest[i + 1 ..];

    // IPv6 字面量：[::1]:4222 —— 方括号形式要先拆出来，
    // 不然 "[::1]:4222" 会被当成裸 IPv6 处理掉。
    if (rest.len > 0 and rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return error.InvalidNatsUrl;
        const host_part = rest[1..close];
        if (host_part.len == 0) return error.InvalidNatsUrl;
        const tail = rest[close + 1 ..];
        var port: u16 = 4222;
        if (tail.len > 0) {
            if (tail[0] != ':') return error.InvalidNatsUrl;
            port = std.fmt.parseInt(u16, tail[1..], 10) catch return error.InvalidNatsUrl;
        }
        return .{ .host = try allocator.dupe(u8, host_part), .port = port, .owned = true };
    }

    // 裸 IPv6 字面量（多个冒号）没有端口，用默认端口
    if (std.mem.count(u8, rest, ":") > 1) {
        if (rest.len == 0) return error.InvalidNatsUrl;
        return .{ .host = try allocator.dupe(u8, rest), .port = 4222, .owned = true };
    }

    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
        const host_part = rest[0..colon];
        const port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch return error.InvalidNatsUrl;
        if (host_part.len == 0) return error.InvalidNatsUrl;
        return .{ .host = try allocator.dupe(u8, host_part), .port = port, .owned = true };
    }
    if (rest.len == 0) return error.InvalidNatsUrl;
    return .{ .host = try allocator.dupe(u8, rest), .port = 4222, .owned = true };
}

/// NATS 线上的一帧。
const Frame = union(enum) {
    /// 控制行（+OK / -ERR / PING / PONG / INFO …），不含行尾 CRLF。
    control: struct { line: []const u8, len: usize },
    /// MSG 帧：MSG <subject> <sid> [reply-to] <#bytes>\r\n<payload>\r\n
    msg: struct {
        subject: []const u8,
        reply_to: ?[]const u8,
        payload: []const u8,
        sid: u64,
        len: usize,
    },
};

/// 扫描 buf 开头的第一帧。
/// 返回 null = 帧没收全（需要更多字节）；error.ProtocolError = 帧头认不出来。
fn scanFrame(buf: []const u8) error{ProtocolError}!?Frame {
    if (buf.len == 0) return null;

    if (std.mem.startsWith(u8, buf, "MSG ")) {
        const nl = std.mem.indexOfScalar(u8, buf, '\n') orelse return null;
        var header = buf[4..nl];
        if (header.len > 0 and header[header.len - 1] == '\r') header = header[0 .. header.len - 1];

        var parts = std.mem.splitScalar(u8, header, ' ');
        const subject = parts.next() orelse return error.ProtocolError;
        const sid_str = parts.next() orelse return error.ProtocolError;
        const sid = std.fmt.parseInt(u64, sid_str, 10) catch return error.ProtocolError;

        var reply_to: ?[]const u8 = null;
        var size_tok = parts.next() orelse return error.ProtocolError;
        const payload_len = std.fmt.parseInt(usize, size_tok, 10) catch blk: {
            reply_to = size_tok;
            size_tok = parts.next() orelse return error.ProtocolError;
            break :blk std.fmt.parseInt(usize, size_tok, 10) catch return error.ProtocolError;
        };

        // 帧长 = 头（含 \n） + payload + 结尾 \r\n
        const total = nl + 1 + payload_len + 2;
        if (buf.len < total) return null;
        return .{ .msg = .{
            .subject = subject,
            .reply_to = reply_to,
            .payload = buf[nl + 1 .. nl + 1 + payload_len],
            .sid = sid,
            .len = total,
        } };
    }

    // 控制行：以 \n 结束（可能带 \r）
    const nl = std.mem.indexOfScalar(u8, buf, '\n') orelse return null;
    var line = buf[0..nl];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    return .{ .control = .{ .line = line, .len = nl + 1 } };
}

pub const NatsClient = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    config: NatsConfig,
    stream: ?std.Io.net.Stream = null,
    sid_counter: u64 = 0,
    subscriptions: std.StringHashMap(Subscription),
    reconnect_attempts: usize = 0,
    /// 已从 socket 读入、还没被帧解析器消费的字节。
    rx: std.ArrayList(u8),
    /// 收到过 PONG —— `ping()` 在等它。
    pong_pending: bool = false,
    /// 帧解析进行中 —— 用来挡住回调里的重入调用。
    parsing: bool = false,
    /// 服务端 INFO 的原文 —— `ServerInfo` 的字段都指向它，由客户端持有。
    info_raw: []const u8 = "",

    pub const Subscription = struct {
        sid: u64,
        subject: []const u8,
        queue_group: ?[]const u8 = null,
        /// 消息回调。回调里不要重入客户端的 poll/ping/request ——
        /// 帧派发期间接收缓冲区正在被消费，重入会读到错位的帧。
        callback: *const fn (Message) void,
    };

    pub const Message = struct {
        subject: []const u8,
        reply_to: ?[]const u8 = null,
        payload: []const u8,
        sid: u64,
    };

    /// Info returned by NATS server on connect (parsed from INFO JSON).
    ///
    /// 字段都指向客户端持有的 INFO 原文 —— 客户端销毁后不要再用。
    pub const ServerInfo = struct {
        server_id: []const u8 = "",
        server_name: []const u8 = "",
        version: []const u8 = "",
        host: []const u8 = "",
        port: u16 = 0,
        max_payload: usize = 1024 * 1024,
        /// 原始 INFO JSON。
        raw_json: []const u8 = "",
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: NatsConfig) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .subscriptions = std.StringHashMap(Subscription).init(allocator),
            .rx = std.ArrayList(u8).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        // Unsubscribe all active subscriptions first
        {
            var it = self.subscriptions.iterator();
            while (it.next()) |entry| {
                self.unsubscribeRaw(entry.value_ptr.sid) catch {};
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.subject);
                if (entry.value_ptr.queue_group) |qg| self.allocator.free(qg);
            }
        }
        self.subscriptions.deinit();
        self.rx.deinit(self.allocator);
        if (self.info_raw.len > 0) self.allocator.free(self.info_raw);

        if (self.stream) |*s| {
            s.close(self.io);
            self.stream = null;
        }
        self.* = undefined;
    }

    /// Establish TCP connection, parse server INFO, and send CONNECT frame.
    /// Returns server info parsed from the INFO line.
    pub fn connect(self: *Self) !ServerInfo {
        const addr = try self.resolveAddress();
        const stream = try addr.connect(self.io, .{ .mode = .stream });
        self.stream = stream;
        self.rx.clearRetainingCapacity();
        errdefer {
            self.stream = null;
            stream.close(self.io);
        }

        // ── Read server INFO ──
        // NATS sends an INFO JSON line on each new connection:
        //   INFO {"server_id":"...","version":"...",...}\r\n
        // 行尾之后多出来的字节留在 rx 里，别丢。
        while (std.mem.indexOfScalar(u8, self.rx.items, '\n') == null) {
            const n = try self.fill();
            if (n == 0) return error.ConnectionError;
            if (self.rx.items.len > 64 * 1024) return error.ConnectionError;
        }
        const nl = std.mem.indexOfScalar(u8, self.rx.items, '\n').?;
        var raw = self.rx.items[0..nl];
        if (raw.len > 0 and raw[raw.len - 1] == '\r') raw = raw[0 .. raw.len - 1];

        // Parse "INFO " prefix
        const info_body: []const u8 = if (std.mem.startsWith(u8, raw, "INFO "))
            raw[5..]
        else
            raw;

        // info_body 指向 rx 内部，而 consume() 会把后面的字节搬上来 ——
        // 所以先把 INFO 原文拷到客户端自己持有的缓冲里，再消费接收缓冲区。
        // `ServerInfo` 的字段都指向这份副本，调用方不需要（也不能）释放。
        const raw_json = try self.allocator.dupe(u8, info_body);
        if (self.info_raw.len > 0) self.allocator.free(self.info_raw);
        self.info_raw = raw_json;
        errdefer {
            self.allocator.free(self.info_raw);
            self.info_raw = "";
        }
        self.consume(nl + 1);

        var server_info = ServerInfo{ .raw_json = self.info_raw };
        server_info.server_id = extractJsonString(self.info_raw, "server_id") orelse "";
        server_info.server_name = extractJsonString(self.info_raw, "server_name") orelse "";
        server_info.version = extractJsonString(self.info_raw, "version") orelse "";
        server_info.host = extractJsonString(self.info_raw, "host") orelse "";
        server_info.port = extractJsonU16(self.info_raw, "port") orelse 4222;
        server_info.max_payload = extractJsonUsize(self.info_raw, "max_payload") orelse 1024 * 1024;

        // ── Send CONNECT ──
        var connect_json = std.ArrayList(u8).empty;
        defer connect_json.deinit(self.allocator);

        // Build JSON using allocPrint + appendSlice (Zig 0.17 no writer() on ArrayList)
        const open = try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\"", .{self.config.name});
        defer self.allocator.free(open);
        try connect_json.appendSlice(self.allocator, open);

        const fixed = try std.fmt.allocPrint(self.allocator, ",\"verbose\":false,\"pedantic\":false,\"lang\":\"zig\",\"version\":\"0.9\"", .{});
        defer self.allocator.free(fixed);
        try connect_json.appendSlice(self.allocator, fixed);

        if (self.config.username) |u| {
            const user_part = try std.fmt.allocPrint(self.allocator, ",\"user\":\"{s}\"", .{u});
            defer self.allocator.free(user_part);
            try connect_json.appendSlice(self.allocator, user_part);
        }
        if (self.config.password) |p| {
            const pass_part = try std.fmt.allocPrint(self.allocator, ",\"pass\":\"{s}\"", .{p});
            defer self.allocator.free(pass_part);
            try connect_json.appendSlice(self.allocator, pass_part);
        }
        if (self.config.token) |t| {
            const token_part = try std.fmt.allocPrint(self.allocator, ",\"auth_token\":\"{s}\"", .{t});
            defer self.allocator.free(token_part);
            try connect_json.appendSlice(self.allocator, token_part);
        }
        try connect_json.append(self.allocator, '}');

        var wbuf: [4096]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        try w.interface.writeAll("CONNECT ");
        try w.interface.writeAll(connect_json.items);
        try w.interface.writeAll("\r\n");
        try w.interface.flush();

        return server_info;
    }

    /// 把配置里的主机名解析成可连接的地址。
    ///
    /// IP 字面量直接用；主机名走 DNS（原来只认点分十进制，
    /// 连默认的 "localhost" 都解析不了 —— 默认配置从来就连不上）。
    fn resolveAddress(self: *Self) !std.Io.net.IpAddress {
        if (std.Io.net.IpAddress.parseIp4(self.config.url, self.config.port)) |a| return a else |_| {}
        if (std.Io.net.IpAddress.parseIp6(self.config.url, self.config.port)) |a| return a else |_| {}

        const host = std.Io.net.HostName.init(self.config.url) catch return error.UnknownHostName;
        var results: [16]std.Io.net.HostName.LookupResult = undefined;
        var queue = std.Io.Queue(std.Io.net.HostName.LookupResult).init(&results);
        try std.Io.net.HostName.lookup(host, self.io, &queue, .{ .port = self.config.port });

        // 优先 IPv4（NATS 部署里最常见），没有再退化到 IPv6。
        var v6: ?std.Io.net.IpAddress = null;
        var buf: [1]std.Io.net.HostName.LookupResult = undefined;
        while (true) {
            const n = queue.get(self.io, &buf, 1) catch |err| switch (err) {
                error.Closed => break,
                error.Canceled => return error.Canceled,
            };
            if (n == 0) break;
            switch (buf[0]) {
                .address => |a| switch (a) {
                    .ip4 => return a,
                    .ip6 => if (v6 == null) {
                        v6 = a;
                    },
                },
                .canonical_name => {},
            }
        }
        if (v6) |a| return a;
        return error.UnknownHostName;
    }

    /// Publish a message to a subject.
    pub fn publish(self: *Self, subject: []const u8, payload: []const u8) !void {
        try self.publishReply(subject, null, payload);
    }

    /// Publish with optional reply subject (for request-reply).
    pub fn publishReply(self: *Self, subject: []const u8, reply_to: ?[]const u8, payload: []const u8) !void {
        const s = self.stream orelse return error.NotConnected;
        var wbuf: [4096]u8 = undefined;
        var w = s.writer(self.io, &wbuf);

        // PUB <subject> [reply-to] <#bytes>\r\n<payload>\r\n
        try w.interface.writeAll("PUB ");
        try w.interface.writeAll(subject);
        try w.interface.writeAll(" ");
        if (reply_to) |rt| {
            try w.interface.writeAll(rt);
            try w.interface.writeAll(" ");
        }
        var size_buf: [32]u8 = undefined;
        const size_str = try std.fmt.bufPrint(&size_buf, "{d}", .{payload.len});
        try w.interface.writeAll(size_str);
        try w.interface.writeAll("\r\n");
        try w.interface.writeAll(payload);
        try w.interface.writeAll("\r\n");
        try w.interface.flush();
    }

    /// Subscribe to a subject with callback. Returns subscription ID (sid).
    pub fn subscribe(self: *Self, subject: []const u8, callback: *const fn (Message) void) !u64 {
        return try self.subscribeGroup(subject, null, callback);
    }

    /// Subscribe with queue group for load-balanced delivery.
    pub fn subscribeGroup(self: *Self, subject: []const u8, queue_group: ?[]const u8, callback: *const fn (Message) void) !u64 {
        const s = self.stream orelse return error.NotConnected;

        self.sid_counter += 1;
        const sid = self.sid_counter;

        var wbuf: [4096]u8 = undefined;
        var w = s.writer(self.io, &wbuf);

        // SUB <subject> [queue group] <sid>\r\n
        try w.interface.writeAll("SUB ");
        try w.interface.writeAll(subject);
        if (queue_group) |qg| {
            try w.interface.writeAll(" ");
            try w.interface.writeAll(qg);
        }
        var sid_buf: [32]u8 = undefined;
        const sid_str = try std.fmt.bufPrint(&sid_buf, " {d}\r\n", .{sid});
        try w.interface.writeAll(sid_str);
        try w.interface.flush();

        const key = try std.fmt.allocPrint(self.allocator, "{d}", .{sid});
        errdefer self.allocator.free(key);
        try self.subscriptions.put(key, .{
            .sid = sid,
            .subject = try self.allocator.dupe(u8, subject),
            .queue_group = if (queue_group) |qg| try self.allocator.dupe(u8, qg) else null,
            .callback = callback,
        });
        return sid;
    }

    /// Unsubscribe from a subscription by its sid.
    pub fn unsubscribe(self: *Self, sid: u64) !void {
        // Send UNSUB command
        self.unsubscribeRaw(sid) catch {};

        // Remove from local subscription map
        const key = try std.fmt.allocPrint(self.allocator, "{d}", .{sid});
        defer self.allocator.free(key);
        if (self.subscriptions.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.subject);
            if (kv.value.queue_group) |qg| self.allocator.free(qg);
        }
    }

    /// Send UNSUB command on the wire without touching the subscription map.
    fn unsubscribeRaw(self: *Self, sid: u64) !void {
        const s = self.stream orelse return error.NotConnected;
        var wbuf: [64]u8 = undefined;
        var w = s.writer(self.io, &wbuf);
        var sid_buf: [32]u8 = undefined;
        const sid_str = try std.fmt.bufPrint(&sid_buf, "UNSUB {d}\r\n", .{sid});
        try w.interface.writeAll(sid_str);
        try w.interface.flush();
    }

    /// Request-reply pattern. Publishes to subject with auto-generated
    /// reply inbox and waits up to timeout_ms for a single response.
    /// Returns the response payload on success (caller owns). Returns error.Timeout.
    pub fn request(self: *Self, subject: []const u8, payload: []const u8, timeout_ms: u64) ![]const u8 {
        if (self.parsing) return error.Reentrant;

        const s = self.stream orelse return error.NotConnected;

        // Generate unique inbox subject
        var inbox_buf: [64]u8 = undefined;
        const inbox = try std.fmt.bufPrint(&inbox_buf, "_INBOX.zf{d}", .{nowMillis(self.io)});

        // Send SUB for the inbox
        self.sid_counter += 1;
        const req_sid = self.sid_counter;
        {
            var wbuf: [256]u8 = undefined;
            var w = s.writer(self.io, &wbuf);
            var sub_buf: [64]u8 = undefined;
            const sub_str = try std.fmt.bufPrint(&sub_buf, "SUB {s} {d}\r\n", .{ inbox, req_sid });
            try w.interface.writeAll(sub_str);
            try w.interface.flush();
        }

        // Send PUB with reply-to = inbox
        try self.publishReply(subject, inbox, payload);

        const deadline = nowMillis(self.io) + @as(i64, @intCast(timeout_ms));
        var result: ?[]const u8 = null;

        while (result == null) {
            const now = nowMillis(self.io);
            if (now >= deadline) {
                self.unsubscribeRaw(req_sid) catch {};
                return error.Timeout;
            }

            // 回应可能已经在缓冲区里了；途中别的订阅的消息照常派发。
            _ = try self.pump(.{ .sid = req_sid, .payload = &result });
            if (result != null) break;

            const rem = deadline - now;
            const timeout: i32 = @intCast(@min(rem, std.math.maxInt(i32)));
            const n = self.fillTimeout(timeout) catch |err| switch (err) {
                error.Timeout => {
                    self.unsubscribeRaw(req_sid) catch {};
                    return error.Timeout;
                },
                else => |e| {
                    self.unsubscribeRaw(req_sid) catch {};
                    return e;
                },
            };
            if (n == 0) {
                self.unsubscribeRaw(req_sid) catch {};
                return error.ConnectionError;
            }
        }

        self.unsubscribeRaw(req_sid) catch {};
        return result.?;
    }

    /// Flush ensures all published messages have been processed by the server.
    /// Sends PING and waits for PONG.
    pub fn flush(self: *Self) !void {
        try self.ping();
    }

    /// Poll for messages. Dispatches matching callbacks.
    /// Returns number of messages processed.
    pub fn poll(self: *Self) !usize {
        // 回调里重入：外层 pump 会把帧派发出去，这里不能再读也等不起。
        if (self.parsing) return 0;

        var p = try self.pump(null);
        if (p.frames > 0) return p.messages;

        const n = try self.fill();
        if (n == 0) return 0;
        p = try self.pump(null);
        return p.messages;
    }

    /// Send PING and expect PONG.
    ///
    /// 服务端会先把 MSG 发回来再回 PONG，所以这里必须扫到真正的 PONG；
    /// 途中遇到的 MSG 照常派发给订阅回调 —— 原来的实现只看一次读的
    /// 前 6 个字节是不是 "PONG\r\n"，既会误报 ProtocolError，
    /// 又会把先到的消息直接丢掉。
    pub fn ping(self: *Self) !void {
        // 回调里重入会死等 PONG（外层 pump 卡在回调里，没人去读）——
        // 直接报错，让调用方知道这条路不能走。
        if (self.parsing) return error.Reentrant;

        const s = self.stream orelse return error.NotConnected;
        var wbuf: [64]u8 = undefined;
        var w = s.writer(self.io, &wbuf);
        try w.interface.writeAll("PING\r\n");
        try w.interface.flush();

        self.pong_pending = false;
        while (true) {
            _ = try self.pump(null);
            if (self.pong_pending) {
                self.pong_pending = false;
                return;
            }
            const n = try self.fill();
            if (n == 0) return error.ConnectionError;
        }
    }

    // ── Internal: receive buffer + frame dispatch ──

    /// 丢掉接收缓冲区前 n 个字节。
    fn consume(self: *Self, n: usize) void {
        if (n == 0) return;
        if (n >= self.rx.items.len) {
            self.rx.clearRetainingCapacity();
            return;
        }
        const rest = self.rx.items[n..];
        std.mem.copyForwards(u8, self.rx.items[0..rest.len], rest);
        self.rx.items.len = rest.len;
    }

    /// 从 socket 读一批字节进接收缓冲区。返回 0 表示对端已关闭。
    fn fill(self: *Self) !usize {
        const s = self.stream orelse return error.NotConnected;
        var chunk: [4096]u8 = undefined;
        const n = try sockread.readSome(s, &chunk);
        if (n > 0) try self.rx.appendSlice(self.allocator, chunk[0..n]);
        return n;
    }

    /// 同 `fill`，但最多等 timeout_ms 毫秒。
    fn fillTimeout(self: *Self, timeout_ms: i32) !usize {
        const s = self.stream orelse return error.NotConnected;
        var chunk: [4096]u8 = undefined;
        const n = try sockread.readSomeTimeout(s, &chunk, timeout_ms);
        if (n > 0) try self.rx.appendSlice(self.allocator, chunk[0..n]);
        return n;
    }

    const PumpResult = struct {
        /// 派发给订阅回调的消息数。
        messages: usize = 0,
        /// 处理的帧数（控制行也算帧）。
        frames: usize = 0,
    };

    /// 让 `pump` 顺带捕获某个 sid 的消息（request-reply 用）。
    const Capture = struct {
        /// 只捕获这个 sid 的消息。
        sid: u64,
        /// 捕获到的 payload（调用方拥有）。
        payload: *?[]const u8,
    };

    /// 解析接收缓冲区里所有完整的帧：MSG 派发给订阅回调，PING 回 PONG，
    /// PONG 记到 `pong_pending`。
    ///
    /// `capture` 非空时，sid 匹配的 MSG 的 payload 会被拷进 `capture.payload`
    /// （用于 request-reply），不再派发给回调。收不全的帧留在缓冲区里。
    fn pump(self: *Self, capture: ?Capture) !PumpResult {
        // 回调里重入：外层 pump 会把这些帧派发出去，这里不能再动缓冲区。
        if (self.parsing) return PumpResult{};
        self.parsing = true;
        defer self.parsing = false;

        var result = PumpResult{};
        var pos: usize = 0;
        var consumed: usize = 0;

        loop: while (pos < self.rx.items.len) {
            const frame = (try scanFrame(self.rx.items[pos..])) orelse break;
            switch (frame) {
                .control => |c| {
                    if (std.mem.eql(u8, c.line, "PONG")) {
                        self.pong_pending = true;
                    } else if (std.mem.eql(u8, c.line, "PING")) {
                        try self.sendPong();
                    } else if (std.mem.startsWith(u8, c.line, "-ERR")) {
                        std.log.warn("[NATS] Server error: {s}", .{c.line});
                    }
                    pos += c.len;
                },
                .msg => |m| {
                    if (capture) |cap| {
                        if (m.sid == cap.sid) {
                            cap.payload.* = try self.allocator.dupe(u8, m.payload);
                            pos += m.len;
                            consumed = pos;
                            break :loop;
                        }
                    }
                    const sid_key = try std.fmt.allocPrint(self.allocator, "{d}", .{m.sid});
                    defer self.allocator.free(sid_key);
                    if (self.subscriptions.get(sid_key)) |sub| {
                        sub.callback(.{
                            .subject = m.subject,
                            .reply_to = m.reply_to,
                            .payload = m.payload,
                            .sid = m.sid,
                        });
                        result.messages += 1;
                    }
                    pos += m.len;
                },
            }
            result.frames += 1;
            consumed = pos;
        }

        if (consumed > 0) self.consume(consumed);
        return result;
    }

    /// 服务端发来 PING（保活），必须回 PONG。
    fn sendPong(self: *Self) !void {
        const s = self.stream orelse return error.NotConnected;
        var wbuf: [64]u8 = undefined;
        var w = s.writer(self.io, &wbuf);
        try w.interface.writeAll("PONG\r\n");
        try w.interface.flush();
    }

    // ── Minimal JSON value extractors ──

    fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
        // Search for "key":"value"
        var search_buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
        const start_idx = std.mem.indexOf(u8, json, needle) orelse return null;
        const val_start = start_idx + needle.len;
        const val_end = std.mem.indexOfScalarPos(u8, json, val_start, '"') orelse return null;
        return json[val_start..val_end];
    }

    fn extractJsonU16(json: []const u8, key: []const u8) ?u16 {
        // Try string value first: "key":"4222"
        if (extractJsonString(json, key)) |s| {
            return std.fmt.parseInt(u16, s, 10) catch null;
        }
        // Try numeric value: "key":4222
        var search_buf: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
        const start_idx = std.mem.indexOf(u8, json, needle) orelse return null;
        const val_start = start_idx + needle.len;
        const val_end = std.mem.indexOfScalarPos(u8, json, val_start, ',') orelse
            std.mem.indexOfScalarPos(u8, json, val_start, '}') orelse json.len;
        const num_str = std.mem.trim(u8, json[val_start..val_end], " \t");
        return std.fmt.parseInt(u16, num_str, 10) catch null;
    }

    fn extractJsonUsize(json: []const u8, key: []const u8) ?usize {
        var search_buf: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
        const start_idx = std.mem.indexOf(u8, json, needle) orelse return null;
        const val_start = start_idx + needle.len;
        const val_end = std.mem.indexOfScalarPos(u8, json, val_start, ',') orelse
            std.mem.indexOfScalarPos(u8, json, val_start, '}') orelse json.len;
        const num_str = std.mem.trim(u8, json[val_start..val_end], " \t");
        return std.fmt.parseInt(usize, num_str, 10) catch null;
    }
};

// ── Tests ──

/// 从环境变量 NATS_URL 取端点。没设置（或为空）返回 null —— 活体测试据此跳过。
fn envEndpoint(allocator: std.mem.Allocator) !?ParsedUrl {
    const raw = std.c.getenv("NATS_URL") orelse return null;
    const span = std.mem.span(raw);
    if (span.len == 0) return null;
    return try parseUrl(allocator, span);
}

test "NatsClient init and deinit" {
    const allocator = std.testing.allocator;
    var client = NatsClient.init(allocator, std.testing.io, .{});
    defer client.deinit();
}

test "NatsConfig defaults" {
    const cfg = NatsConfig{};
    try std.testing.expectEqualStrings("localhost", cfg.url);
    try std.testing.expectEqual(@as(u16, 4222), cfg.port);
    try std.testing.expectEqual(@as(usize, 10), cfg.max_reconnect_attempts);
}

test "parseUrl handles scheme, port, and userinfo" {
    const a = std.testing.allocator;
    {
        const p = try parseUrl(a, "nats://127.0.0.1:4222");
        defer if (p.owned) a.free(p.host);
        try std.testing.expectEqualStrings("127.0.0.1", p.host);
        try std.testing.expectEqual(@as(u16, 4222), p.port);
    }
    {
        const p = try parseUrl(a, "broker.local");
        defer if (p.owned) a.free(p.host);
        try std.testing.expectEqualStrings("broker.local", p.host);
        try std.testing.expectEqual(@as(u16, 4222), p.port);
    }
    {
        const p = try parseUrl(a, "nats://user:pass@broker.local:4333");
        defer if (p.owned) a.free(p.host);
        try std.testing.expectEqualStrings("broker.local", p.host);
        try std.testing.expectEqual(@as(u16, 4333), p.port);
    }
    {
        const p = try parseUrl(a, "nats://[::1]:4222");
        defer if (p.owned) a.free(p.host);
        try std.testing.expectEqualStrings("::1", p.host);
        try std.testing.expectEqual(@as(u16, 4222), p.port);
    }
    try std.testing.expectError(error.InvalidNatsUrl, parseUrl(a, "nats://"));
}

test "scanFrame keeps an incomplete MSG frame" {
    // 帧被拆到两次读里 —— 没收全就不能当成一帧。
    try std.testing.expect((try scanFrame("MSG foo 1 5\r\nab")) == null);
    try std.testing.expect((try scanFrame("MSG foo 1 5\r\n")) == null);

    const full = "MSG foo 1 5\r\nabcde\r\n";
    const frame = (try scanFrame(full)).?;
    try std.testing.expectEqualStrings("foo", frame.msg.subject);
    try std.testing.expectEqualStrings("abcde", frame.msg.payload);
    try std.testing.expectEqual(@as(u64, 1), frame.msg.sid);
    try std.testing.expectEqual(full.len, frame.msg.len);
}

test "scanFrame reads a MSG frame with reply-to" {
    const raw = "MSG foo 7 reply.inbox 3\r\nabc\r\n";
    const frame = (try scanFrame(raw)).?;
    try std.testing.expectEqualStrings("foo", frame.msg.subject);
    try std.testing.expectEqualStrings("reply.inbox", frame.msg.reply_to.?);
    try std.testing.expectEqualStrings("abc", frame.msg.payload);
    try std.testing.expectEqual(raw.len, frame.msg.len);
}

test "scanFrame reads control lines" {
    {
        const frame = (try scanFrame("PONG\r\n")).?;
        try std.testing.expectEqualStrings("PONG", frame.control.line);
        try std.testing.expectEqual(@as(usize, 6), frame.control.len);
    }
    {
        const frame = (try scanFrame("+OK\r\n")).?;
        try std.testing.expectEqualStrings("+OK", frame.control.line);
    }
    try std.testing.expect((try scanFrame("PO")) == null);
}

test "NATS client resolves a hostname" {
    // "localhost" 必须能解析 —— 原来只认点分十进制，默认配置从来连不上。
    const a = std.testing.allocator;
    var client = NatsClient.init(a, std.testing.io, .{ .url = "localhost" });
    defer client.deinit();
    const addr = try client.resolveAddress();
    switch (addr) {
        .ip4 => try std.testing.expectEqual(@as(u8, 127), addr.ip4.bytes[0]),
        .ip6 => {
            // ::1
            var leading_zero = true;
            for (addr.ip6.bytes[0..15]) |b| {
                if (b != 0) leading_zero = false;
            }
            try std.testing.expect(leading_zero);
            try std.testing.expectEqual(@as(u8, 1), addr.ip6.bytes[15]);
        },
    }
}

test "NATS connect and ping" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const endpoint = (try envEndpoint(allocator)) orelse return error.SkipZigTest;
    defer if (endpoint.owned) allocator.free(endpoint.host);

    var client = NatsClient.init(allocator, std.testing.io, .{
        .url = endpoint.host,
        .port = endpoint.port,
    });
    defer client.deinit();

    const info = try client.connect();
    try std.testing.expect(info.server_id.len > 0);
    try std.testing.expect(info.version.len > 0);

    // Ping/PONG heartbeat
    try client.ping();
    try client.ping();
}

var g_nats_soak_hits: std.atomic.Value(usize) = .init(0);

test "NATS publish and subscribe" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const endpoint = (try envEndpoint(allocator)) orelse return error.SkipZigTest;
    defer if (endpoint.owned) allocator.free(endpoint.host);

    var client = NatsClient.init(allocator, std.testing.io, .{
        .url = endpoint.host,
        .port = endpoint.port,
    });
    defer client.deinit();

    _ = try client.connect();

    g_nats_soak_hits.store(0, .monotonic);
    const sid = try client.subscribe("zfinal.test.pubsub", struct {
        fn handler(msg: NatsClient.Message) void {
            if (std.mem.eql(u8, msg.payload, "hello-nats-soak")) {
                _ = g_nats_soak_hits.fetchAdd(1, .monotonic);
            }
        }
    }.handler);
    defer client.unsubscribe(sid) catch {};

    try client.publish("zfinal.test.pubsub", "hello-nats-soak");
    try client.flush();

    var waited: usize = 0;
    while (g_nats_soak_hits.load(.monotonic) == 0 and waited < 40) : (waited += 1) {
        _ = try client.poll();
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(25), .real) catch {};
    }
    try std.testing.expect(g_nats_soak_hits.load(.monotonic) >= 1);
}

var g_nats_ping_hits: std.atomic.Value(usize) = .init(0);

test "NATS ping does not swallow a queued message" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const endpoint = (try envEndpoint(allocator)) orelse return error.SkipZigTest;
    defer if (endpoint.owned) allocator.free(endpoint.host);

    var client = NatsClient.init(allocator, std.testing.io, .{
        .url = endpoint.host,
        .port = endpoint.port,
    });
    defer client.deinit();

    _ = try client.connect();

    g_nats_ping_hits.store(0, .monotonic);
    const sid = try client.subscribe("zfinal.test.ping.msg", struct {
        fn handler(msg: NatsClient.Message) void {
            if (std.mem.eql(u8, msg.payload, "ping-msg")) {
                _ = g_nats_ping_hits.fetchAdd(1, .monotonic);
            }
        }
    }.handler);
    defer client.unsubscribe(sid) catch {};

    try client.publish("zfinal.test.ping.msg", "ping-msg");
    // 服务端先把 MSG 发回来、再回 PONG。ping 必须扫到真正的 PONG，
    // 途中那条 MSG 还得原样送到订阅回调。
    try client.ping();

    var waited: usize = 0;
    while (g_nats_ping_hits.load(.monotonic) == 0 and waited < 40) : (waited += 1) {
        _ = try client.poll();
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(25), .real) catch {};
    }
    try std.testing.expect(g_nats_ping_hits.load(.monotonic) >= 1);
}

/// 回调里重入客户端时用的通道（回调签名没有 userdata，只能走全局）。
var g_reentrant_client: ?*NatsClient = null;
var g_reentrant_poll_result: std.atomic.Value(i64) = .init(-1);
/// 回调递归深度封顶 —— 没有重入保护时这里会无限递归，
/// 掐断它好让断言报出失败，而不是把整个测试二进制挂死。
var g_reentrant_depth: std.atomic.Value(usize) = .init(0);

test "NATS client rejects re-entrant calls while dispatching frames" {
    const allocator = std.testing.allocator;
    var client = NatsClient.init(allocator, std.testing.io, .{});
    defer client.deinit();

    // 模拟"正在派发帧"的状态：回调里重入客户端就是这个状态。
    client.parsing = true;
    defer client.parsing = false;

    // poll 必须立刻返回 0 —— 不能读接收缓冲区，也不能等。
    try std.testing.expectEqual(@as(usize, 0), try client.poll());

    // ping 必须报错 —— 死等 PONG 会把外层派发卡死。
    try std.testing.expectError(error.Reentrant, client.ping());

    // request 同理。
    try std.testing.expectError(error.Reentrant, client.request("s", "p", 10));
}

test "NATS callback re-entry does not corrupt the stream" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const endpoint = (try envEndpoint(allocator)) orelse return error.SkipZigTest;
    defer if (endpoint.owned) allocator.free(endpoint.host);

    var client = NatsClient.init(allocator, std.testing.io, .{
        .url = endpoint.host,
        .port = endpoint.port,
    });
    defer client.deinit();

    _ = try client.connect();

    g_reentrant_client = &client;
    defer g_reentrant_client = null;
    g_reentrant_poll_result.store(-1, .monotonic);
    g_reentrant_depth.store(0, .monotonic);

    const sid = try client.subscribe("zfinal.test.reentrant", struct {
        fn handler(msg: NatsClient.Message) void {
            _ = msg;
            const c = g_reentrant_client orelse return;
            const depth = g_reentrant_depth.fetchAdd(1, .monotonic);
            defer _ = g_reentrant_depth.fetchSub(1, .monotonic);
            if (depth > 0) return;

            // 重入 poll：必须立刻返回 0，不能再读接收缓冲区。
            const n = c.poll() catch 0;
            g_reentrant_poll_result.store(@intCast(n), .monotonic);
        }
    }.handler);
    defer client.unsubscribe(sid) catch {};

    try client.publish("zfinal.test.reentrant", "reenter");
    try client.ping();

    var waited: usize = 0;
    while (g_reentrant_poll_result.load(.monotonic) == -1 and waited < 40) : (waited += 1) {
        _ = try client.poll();
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(25), .real) catch {};
    }

    // 内层 poll 立刻返回 0 —— 那条消息由外层 pump 派发。
    // 没有重入保护时内层会再读到同一条消息（返回值 1）并把缓冲区读错位。
    try std.testing.expectEqual(@as(i64, 0), g_reentrant_poll_result.load(.monotonic));

    // 重入之后连接还是好的 —— 缓冲区没被读错位。
    try client.ping();
}

test "NATS request-reply" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const endpoint = (try envEndpoint(allocator)) orelse return error.SkipZigTest;
    defer if (endpoint.owned) allocator.free(endpoint.host);

    var client = NatsClient.init(allocator, std.testing.io, .{
        .url = endpoint.host,
        .port = endpoint.port,
    });
    defer client.deinit();

    _ = try client.connect();

    // Subscribe to respond to requests
    const sid = try client.subscribe("zfinal.test.request", struct {
        fn handler(msg: NatsClient.Message) void {
            _ = msg;
        }
    }.handler);
    defer client.unsubscribe(sid) catch {};

    // Send a request — will timeout (no responder), but validates protocol
    _ = client.request("zfinal.test.request", "ping", 1000) catch |err| {
        try std.testing.expectEqual(error.Timeout, err);
        return;
    };
}
