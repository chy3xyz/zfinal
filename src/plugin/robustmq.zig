//! Kafka-protocol client targeting **RobustMQ** (and any Kafka-compatible broker).
//!
//! RobustMQ exposes a Kafka wire endpoint (default `127.0.0.1:9092`). This module
//! speaks the standard Kafka request framing (ApiVersions + Produce + Fetch) over
//! TCP via `std.Io` — same approach as zigmodu `KafkaConnector`, zero third-party deps.
//!
//! Pair with in-process `QueueClient` and `QueueNatsClient`:
//! - memory → single process
//! - NATS → NATS protocol brokers (`QueueNatsClient`, zero-dep wire client)
//! - RobustMQ → Kafka protocol (this file)
//!
//! Unit tests use offline mode (no network). Live I/O tests require
//! `ROBUSTMQ_URL` or `KAFKA_BOOTSTRAP` (e.g. `127.0.0.1:9092`).

const std = @import("std");
const builtin = @import("builtin");
const io_instance = @import("../io_instance.zig");

fn nowSeconds() i64 {
    return std.Io.Timestamp.now(io_instance.io, .real).toSeconds();
}

fn nowMillis() i64 {
    return std.Io.Timestamp.now(io_instance.io, .real).toMilliseconds();
}

pub const KafkaMessage = struct {
    topic: []const u8,
    key: ?[]const u8,
    value: []const u8,
    headers: []const Header,
    timestamp: i64,
    partition: i32 = 0,

    pub const Header = struct {
        key: []const u8,
        value: []const u8,
    };
};

pub const KafkaProducerConfig = struct {
    /// RobustMQ / Kafka bootstrap: `host:port` (default RobustMQ Kafka listener).
    bootstrap_servers: []const u8 = "127.0.0.1:9092",
    client_id: []const u8 = "zfinal-robustmq",
    acks: Acks = .leader,
    compression: Compression = .none,
    batch_size: usize = 16384,
    linger_ms: u64 = 0,
    /// When true, `send` only updates local stats (unit tests).
    offline: bool = false,
    connect_timeout_ms: u64 = 5000,

    pub const Acks = enum(i8) {
        none = 0,
        leader = 1,
        all = -1,
    };

    pub const Compression = enum {
        none,
        gzip,
        snappy,
        lz4,
    };
};

pub const KafkaConsumerConfig = struct {
    bootstrap_servers: []const u8 = "127.0.0.1:9092",
    group_id: []const u8 = "zfinal-group",
    client_id: []const u8 = "zfinal-robustmq",
    auto_offset_reset: []const u8 = "latest",
    enable_auto_commit: bool = true,
    max_poll_records: usize = 500,
    session_timeout_ms: u64 = 45000,
    offline: bool = false,
    /// Partitions per subscribed topic for the classic **range** assignor.
    /// Used until Metadata API discovers real counts; set to match broker topic layout.
    partition_count: i32 = 1,
};

/// Low-level Kafka wire client used by producer/consumer against RobustMQ.
pub const RobustMQTransport = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    stream: ?std.Io.net.Stream = null,
    correlation_id: i32 = 1,
    client_id: []const u8,
    host: []const u8,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, bootstrap: []const u8, client_id: []const u8) !Self {
        const host, const port = try parseBootstrap(bootstrap);
        return .{
            .allocator = allocator,
            .io = io,
            .client_id = client_id,
            .host = host,
            .port = port,
        };
    }

    pub fn deinit(self: *Self) void {
        self.close();
        self.* = undefined;
    }

    pub fn close(self: *Self) void {
        if (self.stream) |*s| {
            s.close(self.io);
            self.stream = null;
        }
    }

    pub fn connect(self: *Self) !void {
        if (self.stream != null) return;
        const addr = try std.Io.net.IpAddress.parseIp4(self.host, self.port);
        const stream = try addr.connect(self.io, .{ .mode = .stream });
        self.stream = stream;
        // Negotiate API versions (best-effort; ignore body details).
        self.sendApiVersions() catch |err| {
            std.log.warn("[RobustMQ] ApiVersions handshake failed: {s}", .{@errorName(err)});
        };
    }

    pub fn ensureConnected(self: *Self) !void {
        try self.connect();
    }

    pub fn produce(
        self: *Self,
        topic: []const u8,
        partition: i32,
        key: ?[]const u8,
        value: []const u8,
        acks: i16,
    ) !void {
        try self.ensureConnected();
        const corr = self.nextCorrelation();
        const body = try KafkaWireFormat.buildProduceRequest(
            self.allocator,
            topic,
            partition,
            key,
            value,
            corr,
            self.client_id,
            acks,
        );
        defer self.allocator.free(body);
        try self.writeFrame(body);
        const resp = try self.readFrame();
        defer self.allocator.free(resp);
        try KafkaWireFormat.checkProduceResponse(resp, corr);
    }

    /// Fetch up to `max_bytes` from topic/partition starting at `offset`.
    /// Returns owned slice of message values (caller frees each + the slice).
    pub fn fetch(
        self: *Self,
        topic: []const u8,
        partition: i32,
        offset: i64,
        max_bytes: i32,
    ) ![][]const u8 {
        try self.ensureConnected();
        const corr = self.nextCorrelation();
        const body = try KafkaWireFormat.buildFetchRequest(
            self.allocator,
            topic,
            partition,
            offset,
            max_bytes,
            corr,
            self.client_id,
        );
        defer self.allocator.free(body);
        try self.writeFrame(body);
        const resp = try self.readFrame();
        defer self.allocator.free(resp);
        return KafkaWireFormat.parseFetchValues(self.allocator, resp);
    }

    /// Commit a single topic/partition offset for `group_id` (OffsetCommit API key 8).
    /// Pass `generation_id` / `member_id` from `joinGroup`; `-1` / `""` is admin-only.
    pub fn offsetCommit(
        self: *Self,
        group_id: []const u8,
        generation_id: i32,
        member_id: []const u8,
        topic: []const u8,
        partition: i32,
        offset: i64,
        metadata: []const u8,
    ) !void {
        try self.ensureConnected();
        const corr = self.nextCorrelation();
        const body = try KafkaWireFormat.buildOffsetCommitRequest(
            self.allocator,
            group_id,
            generation_id,
            member_id,
            topic,
            partition,
            offset,
            metadata,
            corr,
            self.client_id,
        );
        defer self.allocator.free(body);
        try self.writeFrame(body);
        const resp = try self.readFrame();
        defer self.allocator.free(resp);
        try KafkaWireFormat.checkOffsetCommitResponse(resp, corr);
    }

    /// JoinGroup (API key 11, v1). Caller owns `result` via `JoinGroupResult.deinit`.
    pub fn joinGroup(
        self: *Self,
        group_id: []const u8,
        member_id: []const u8,
        session_timeout_ms: i32,
        rebalance_timeout_ms: i32,
        protocol_type: []const u8,
        protocol_name: []const u8,
        protocol_metadata: []const u8,
    ) !KafkaWireFormat.JoinGroupResult {
        try self.ensureConnected();
        const corr = self.nextCorrelation();
        const body = try KafkaWireFormat.buildJoinGroupRequest(
            self.allocator,
            group_id,
            session_timeout_ms,
            rebalance_timeout_ms,
            member_id,
            protocol_type,
            protocol_name,
            protocol_metadata,
            corr,
            self.client_id,
        );
        defer self.allocator.free(body);
        try self.writeFrame(body);
        const resp = try self.readFrame();
        defer self.allocator.free(resp);
        return try KafkaWireFormat.parseJoinGroupResponse(self.allocator, resp, corr);
    }

    /// SyncGroup (API key 14, v0). Leader sends assignments; followers send empty list.
    /// Returns owned ConsumerProtocolAssignment bytes for this member (may be empty).
    pub fn syncGroup(
        self: *Self,
        group_id: []const u8,
        generation_id: i32,
        member_id: []const u8,
        assignments: []const KafkaWireFormat.GroupAssignment,
    ) ![]u8 {
        try self.ensureConnected();
        const corr = self.nextCorrelation();
        const body = try KafkaWireFormat.buildSyncGroupRequest(
            self.allocator,
            group_id,
            generation_id,
            member_id,
            assignments,
            corr,
            self.client_id,
        );
        defer self.allocator.free(body);
        try self.writeFrame(body);
        const resp = try self.readFrame();
        defer self.allocator.free(resp);
        return try KafkaWireFormat.parseSyncGroupResponse(self.allocator, resp, corr);
    }

    /// Heartbeat (API key 12, v0) — keep membership alive between polls.
    pub fn heartbeat(
        self: *Self,
        group_id: []const u8,
        generation_id: i32,
        member_id: []const u8,
    ) !void {
        try self.ensureConnected();
        const corr = self.nextCorrelation();
        const body = try KafkaWireFormat.buildHeartbeatRequest(
            self.allocator,
            group_id,
            generation_id,
            member_id,
            corr,
            self.client_id,
        );
        defer self.allocator.free(body);
        try self.writeFrame(body);
        const resp = try self.readFrame();
        defer self.allocator.free(resp);
        try KafkaWireFormat.checkHeartbeatResponse(resp, corr);
    }

    /// LeaveGroup (API key 13, v0).
    pub fn leaveGroup(
        self: *Self,
        group_id: []const u8,
        member_id: []const u8,
    ) !void {
        try self.ensureConnected();
        const corr = self.nextCorrelation();
        const body = try KafkaWireFormat.buildLeaveGroupRequest(
            self.allocator,
            group_id,
            member_id,
            corr,
            self.client_id,
        );
        defer self.allocator.free(body);
        try self.writeFrame(body);
        const resp = try self.readFrame();
        defer self.allocator.free(resp);
        try KafkaWireFormat.checkLeaveGroupResponse(resp, corr);
    }

    /// OffsetFetch (API key 9, v1) — one topic / one partition.
    pub fn offsetFetch(
        self: *Self,
        group_id: []const u8,
        topic: []const u8,
        partition: i32,
    ) !i64 {
        try self.ensureConnected();
        const corr = self.nextCorrelation();
        const body = try KafkaWireFormat.buildOffsetFetchRequest(
            self.allocator,
            group_id,
            topic,
            partition,
            corr,
            self.client_id,
        );
        defer self.allocator.free(body);
        try self.writeFrame(body);
        const resp = try self.readFrame();
        defer self.allocator.free(resp);
        return try KafkaWireFormat.parseOffsetFetchResponse(resp, corr);
    }

    fn nextCorrelation(self: *Self) i32 {
        const id = self.correlation_id;
        self.correlation_id +%= 1;
        return id;
    }

    fn writeFrame(self: *Self, payload: []const u8) !void {
        const s = self.stream orelse return error.NotConnected;
        var size_be: [4]u8 = undefined;
        writeI32(&size_be, @intCast(payload.len));
        var wbuf: [8192]u8 = undefined;
        var w = s.writer(self.io, &wbuf);
        try w.interface.writeAll(&size_be);
        try w.interface.writeAll(payload);
        try w.interface.flush();
    }

    fn readFrame(self: *Self) ![]u8 {
        const s = self.stream orelse return error.NotConnected;
        var size_buf: [4]u8 = undefined;
        try readExact(s, self.io, &size_buf);
        const size = readI32(&size_buf);
        if (size <= 0 or size > 16 * 1024 * 1024) return error.InvalidFrame;
        const buf = try self.allocator.alloc(u8, @intCast(size));
        errdefer self.allocator.free(buf);
        try readExact(s, self.io, buf);
        return buf;
    }

    fn sendApiVersions(self: *Self) !void {
        const corr = self.nextCorrelation();
        const body = try KafkaWireFormat.buildApiVersionsRequest(self.allocator, corr, self.client_id);
        defer self.allocator.free(body);
        try self.writeFrame(body);
        const resp = try self.readFrame();
        defer self.allocator.free(resp);
        if (resp.len < 4) return error.InvalidResponse;
        const got = readI32(resp[0..4]);
        if (got != corr) return error.CorrelationMismatch;
    }
};

fn parseBootstrap(bootstrap: []const u8) !struct { []const u8, u16 } {
    // Take first host:port from "h1:9092,h2:9092"
    const first = if (std.mem.indexOfScalar(u8, bootstrap, ',')) |i| bootstrap[0..i] else bootstrap;
    const trimmed = std.mem.trim(u8, first, " \t");
    if (std.mem.lastIndexOfScalar(u8, trimmed, ':')) |colon| {
        const host = trimmed[0..colon];
        const port = try std.fmt.parseInt(u16, trimmed[colon + 1 ..], 10);
        if (host.len == 0) return error.InvalidBootstrap;
        return .{ host, port };
    }
    return .{ trimmed, 9092 };
}

fn readExact(stream: std.Io.net.Stream, io: std.Io, buf: []u8) !void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = stream.read(io, data: {
            var d: [1][]u8 = .{buf[filled..]};
            break :data &d;
        }) catch return error.ConnectionError;
        if (n == 0) return error.ConnectionClosed;
        filled += n;
    }
}

fn writeI32(out: *[4]u8, v: i32) void {
    const u: u32 = @bitCast(v);
    out[0] = @truncate(u >> 24);
    out[1] = @truncate(u >> 16);
    out[2] = @truncate(u >> 8);
    out[3] = @truncate(u);
}

fn readI32(buf: []const u8) i32 {
    const u: u32 = (@as(u32, buf[0]) << 24) | (@as(u32, buf[1]) << 16) | (@as(u32, buf[2]) << 8) | buf[3];
    return @bitCast(u);
}

fn readI64(buf: []const u8) i64 {
    const u: u64 =
        (@as(u64, buf[0]) << 56) |
        (@as(u64, buf[1]) << 48) |
        (@as(u64, buf[2]) << 40) |
        (@as(u64, buf[3]) << 32) |
        (@as(u64, buf[4]) << 24) |
        (@as(u64, buf[5]) << 16) |
        (@as(u64, buf[6]) << 8) |
        buf[7];
    return @bitCast(u);
}

fn writeI16(out: *[2]u8, v: i16) void {
    const u: u16 = @bitCast(v);
    out[0] = @truncate(u >> 8);
    out[1] = @truncate(u);
}

fn readI16(buf: []const u8) i16 {
    const u: u16 = (@as(u16, buf[0]) << 8) | buf[1];
    return @bitCast(u);
}

pub const KafkaProducer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: KafkaProducerConfig,
    topic_stats: std.StringHashMap(TopicStats),
    transport: ?RobustMQTransport = null,
    io: ?std.Io = null,

    pub const TopicStats = struct {
        produced: u64 = 0,
        failed: u64 = 0,
        last_produced_at: i64 = 0,
    };

    /// Offline / unit-test constructor (no network).
    pub fn init(allocator: std.mem.Allocator, config: KafkaProducerConfig) Self {
        var cfg = config;
        cfg.offline = true;
        return .{
            .allocator = allocator,
            .config = cfg,
            .topic_stats = std.StringHashMap(TopicStats).init(allocator),
        };
    }

    /// Online constructor — connects lazily to RobustMQ / Kafka on first `send`.
    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io, config: KafkaProducerConfig) Self {
        var cfg = config;
        cfg.offline = false;
        return .{
            .allocator = allocator,
            .config = cfg,
            .topic_stats = std.StringHashMap(TopicStats).init(allocator),
            .io = io,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.transport) |*t| t.deinit();
        self.topic_stats.deinit();
        self.* = undefined;
    }

    pub fn send(self: *Self, msg: KafkaMessage) !void {
        if (!self.config.offline) {
            try self.ensureTransport();
            const acks: i16 = switch (self.config.acks) {
                .none => 0,
                .leader => 1,
                .all => -1,
            };
            self.transport.?.produce(msg.topic, msg.partition, msg.key, msg.value, acks) catch |err| {
                try self.bumpFailed(msg.topic);
                return err;
            };
        }

        const entry = try self.topic_stats.getOrPut(msg.topic);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.produced += 1;
        entry.value_ptr.last_produced_at = nowSeconds();
    }

    pub fn sendBatch(self: *Self, messages: []const KafkaMessage) !void {
        for (messages) |msg| try self.send(msg);
    }

    pub fn getTopicStats(self: *Self, topic: []const u8) ?TopicStats {
        return self.topic_stats.get(topic);
    }

    pub fn flush(self: *Self) !void {
        _ = self;
    }

    pub fn close(self: *Self) void {
        if (self.transport) |*t| t.close();
    }

    fn ensureTransport(self: *Self) !void {
        if (self.transport != null) return;
        const io = self.io orelse return error.IoRequired;
        var t = try RobustMQTransport.init(self.allocator, io, self.config.bootstrap_servers, self.config.client_id);
        errdefer t.deinit();
        try t.connect();
        self.transport = t;
    }

    fn bumpFailed(self: *Self, topic: []const u8) !void {
        const entry = try self.topic_stats.getOrPut(topic);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.failed += 1;
    }
};

pub const KafkaConsumer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: KafkaConsumerConfig,
    subscriptions: std.StringHashMap(Subscription),
    is_running: bool,
    transport: ?RobustMQTransport = null,
    io: ?std.Io = null,
    /// Offset cursor keyed by `topic\x1fpartition` (see `offsetKeyBuf`).
    offsets: std.StringHashMap(i64),
    /// Assigned partitions per topic after `join()` (owned slices).
    assigned: std.StringHashMap([]i32),
    /// From JoinGroup; `-1` until `join()`.
    generation_id: i32 = -1,
    /// Owned after successful `join()`; empty otherwise.
    member_id: []u8 = &.{},

    pub const Subscription = struct {
        topic: []const u8,
        handler: *const fn (KafkaMessage) void,
    };

    pub fn init(allocator: std.mem.Allocator, config: KafkaConsumerConfig) Self {
        var cfg = config;
        cfg.offline = true;
        return .{
            .allocator = allocator,
            .config = cfg,
            .subscriptions = std.StringHashMap(Subscription).init(allocator),
            .is_running = false,
            .offsets = std.StringHashMap(i64).init(allocator),
            .assigned = std.StringHashMap([]i32).init(allocator),
        };
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io, config: KafkaConsumerConfig) Self {
        var cfg = config;
        cfg.offline = false;
        return .{
            .allocator = allocator,
            .config = cfg,
            .subscriptions = std.StringHashMap(Subscription).init(allocator),
            .is_running = false,
            .io = io,
            .offsets = std.StringHashMap(i64).init(allocator),
            .assigned = std.StringHashMap([]i32).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.transport) |*t| t.deinit();
        if (self.member_id.len > 0) self.allocator.free(self.member_id);
        self.clearAssignments();
        var iter = self.subscriptions.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.topic);
        }
        self.subscriptions.deinit();
        var oit = self.offsets.iterator();
        while (oit.next()) |e| self.allocator.free(e.key_ptr.*);
        self.offsets.deinit();
        self.assigned.deinit();
        self.* = undefined;
    }

    pub fn subscribe(self: *Self, topic: []const u8, handler: *const fn (KafkaMessage) void) !void {
        const topic_copy = try self.allocator.dupe(u8, topic);
        errdefer self.allocator.free(topic_copy);
        try self.subscriptions.put(topic_copy, .{ .topic = topic_copy, .handler = handler });
        try self.putOffset(topic_copy, 0, 0);
        std.log.info("[KafkaConsumer] Subscribed to topic: {s}", .{topic});
    }

    pub fn unsubscribe(self: *Self, topic: []const u8) void {
        if (self.subscriptions.fetchRemove(topic)) |removed| {
            self.allocator.free(removed.key);
        }
        self.removeOffsetsForTopic(topic);
        if (self.assigned.fetchRemove(topic)) |rem| {
            self.allocator.free(rem.key);
            self.allocator.free(rem.value);
        }
    }

    pub fn getSubscriptions(self: *Self) ![]const []const u8 {
        var result = std.ArrayList([]const u8).empty;
        var iter = self.subscriptions.keyIterator();
        while (iter.next()) |key| {
            try result.append(self.allocator, key.*);
        }
        return result.toOwnedSlice(self.allocator);
    }

    pub fn start(self: *Self) void {
        self.is_running = true;
    }

    pub fn stop(self: *Self) void {
        self.is_running = false;
        if (self.transport) |*t| t.close();
    }

    /// Poll RobustMQ for each assigned partition (partition 0 before join).
    pub fn poll(self: *Self) !usize {
        if (self.config.offline or !self.is_running) return 0;
        try self.ensureTransport();
        var delivered: usize = 0;
        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            const topic = entry.value_ptr.topic;
            const parts = self.partitionsFor(topic);
            for (parts) |partition| {
                const offset = self.getOffset(topic, partition) orelse 0;
                const values = self.transport.?.fetch(topic, partition, offset, 1024 * 1024) catch |err| {
                    std.log.warn("[KafkaConsumer] fetch {s}/{d} failed: {s}", .{ topic, partition, @errorName(err) });
                    continue;
                };
                defer {
                    for (values) |v| self.allocator.free(v);
                    self.allocator.free(values);
                }
                for (values) |v| {
                    entry.value_ptr.handler(.{
                        .topic = topic,
                        .key = null,
                        .value = v,
                        .headers = &.{},
                        .timestamp = nowSeconds(),
                        .partition = partition,
                    });
                    delivered += 1;
                }
                if (values.len > 0) {
                    const next = offset + @as(i64, @intCast(values.len));
                    try self.putOffset(topic, partition, next);
                    if (self.config.enable_auto_commit) {
                        self.commitBroker(topic, partition, next) catch |err| {
                            std.log.warn("[KafkaConsumer] OffsetCommit {s}/{d} failed: {s}", .{ topic, partition, @errorName(err) });
                        };
                    }
                }
            }
        }
        return delivered;
    }

    /// Update the in-process fetch cursor for topic partition 0 (compat).
    pub fn commitLocal(self: *Self, topic: []const u8, offset: i64) !void {
        try self.commitLocalPartition(topic, 0, offset);
    }

    pub fn commitLocalPartition(self: *Self, topic: []const u8, partition: i32, offset: i64) !void {
        if (!self.subscriptions.contains(topic)) return error.NotSubscribed;
        try self.putOffset(topic, partition, offset);
    }

    pub fn getOffset(self: *Self, topic: []const u8, partition: i32) ?i64 {
        var key_buf: [512]u8 = undefined;
        const key = offsetKeyBuf(&key_buf, topic, partition) catch return null;
        return self.offsets.get(key);
    }

    /// Local commit + best-effort broker OffsetCommit when online.
    pub fn commit(self: *Self, topic: []const u8, partition: i32, offset: i64) !void {
        try self.commitLocalPartition(topic, partition, offset);
        try self.commitBroker(topic, partition, offset);
    }

    /// JoinGroup + SyncGroup with classic **range** assignor.
    /// Leader divides `0..partition_count-1` across members (lexicographic member_id)
    /// per subscribed topic. Set `partition_count` to match broker topic layout.
    pub fn join(self: *Self) !void {
        if (self.config.offline) return;
        if (self.config.group_id.len == 0) return error.GroupIdRequired;
        if (self.subscriptions.count() == 0) return error.NoSubscriptions;
        if (self.config.partition_count < 1) return error.InvalidPartitionCount;
        try self.ensureTransport();

        var topics = std.ArrayList([]const u8).empty;
        defer topics.deinit(self.allocator);
        var it = self.subscriptions.keyIterator();
        while (it.next()) |key| {
            try topics.append(self.allocator, key.*);
        }

        const meta = try KafkaWireFormat.buildConsumerProtocolMetadata(self.allocator, topics.items);
        defer self.allocator.free(meta);

        var result = try self.transport.?.joinGroup(
            self.config.group_id,
            self.member_id,
            @intCast(self.config.session_timeout_ms),
            30000,
            "consumer",
            "range",
            meta,
        );
        defer result.deinit(self.allocator);

        if (self.member_id.len > 0) self.allocator.free(self.member_id);
        self.member_id = try self.allocator.dupe(u8, result.member_id);
        self.generation_id = result.generation_id;

        const assignment_bytes = if (result.isLeader())
            try self.leaderSyncAssign(&result, topics.items)
        else
            try self.transport.?.syncGroup(
                self.config.group_id,
                self.generation_id,
                self.member_id,
                &.{},
            );
        defer self.allocator.free(assignment_bytes);

        try self.applyAssignmentBytes(assignment_bytes);
    }

    pub fn heartbeat(self: *Self) !void {
        if (self.config.offline) return;
        if (self.generation_id < 0 or self.member_id.len == 0) return error.NotJoined;
        try self.ensureTransport();
        try self.transport.?.heartbeat(self.config.group_id, self.generation_id, self.member_id);
    }

    pub fn leave(self: *Self) !void {
        if (self.config.offline) {
            self.generation_id = -1;
            if (self.member_id.len > 0) {
                self.allocator.free(self.member_id);
                self.member_id = &.{};
            }
            self.clearAssignments();
            return;
        }
        if (self.member_id.len == 0) return;
        try self.ensureTransport();
        try self.transport.?.leaveGroup(self.config.group_id, self.member_id);
        self.generation_id = -1;
        self.allocator.free(self.member_id);
        self.member_id = &.{};
        self.clearAssignments();
    }

    pub fn fetchCommittedOffset(self: *Self, topic: []const u8) !?i64 {
        return self.fetchCommittedOffsetPartition(topic, 0);
    }

    pub fn fetchCommittedOffsetPartition(self: *Self, topic: []const u8, partition: i32) !?i64 {
        if (self.config.offline) return self.getOffset(topic, partition);
        if (self.config.group_id.len == 0) return error.GroupIdRequired;
        try self.ensureTransport();
        const off = try self.transport.?.offsetFetch(self.config.group_id, topic, partition);
        if (off < 0) return null;
        try self.putOffset(topic, partition, off);
        return off;
    }

    pub fn getAssignedPartitions(self: *Self, topic: []const u8) []const i32 {
        return self.partitionsFor(topic);
    }

    fn leaderSyncAssign(self: *Self, result: *KafkaWireFormat.JoinGroupResult, topics: []const []const u8) ![]u8 {
        var member_ids = try self.allocator.alloc([]const u8, result.members.len);
        defer self.allocator.free(member_ids);
        for (result.members, 0..) |m, i| member_ids[i] = m.member_id;
        std.mem.sort([]const u8, member_ids, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);

        const ranges = try KafkaWireFormat.rangeAssign(self.allocator, self.config.partition_count, member_ids.len);
        defer {
            for (ranges) |r| self.allocator.free(r);
            self.allocator.free(ranges);
        }

        var assigns = std.ArrayList(KafkaWireFormat.GroupAssignment).empty;
        defer {
            for (assigns.items) |a| self.allocator.free(a.assignment);
            assigns.deinit(self.allocator);
        }

        var my_bytes: ?[]u8 = null;
        for (member_ids, 0..) |mid, mi| {
            var tps = try self.allocator.alloc(KafkaWireFormat.TopicPartitions, topics.len);
            defer self.allocator.free(tps);
            for (topics, 0..) |t, ti| {
                tps[ti] = .{ .topic = t, .partitions = ranges[mi] };
            }
            const bytes = try KafkaWireFormat.buildMemberAssignmentTopics(self.allocator, tps);
            try assigns.append(self.allocator, .{ .member_id = mid, .assignment = bytes });
            if (std.mem.eql(u8, mid, self.member_id)) {
                my_bytes = try self.allocator.dupe(u8, bytes);
            }
        }

        const received = try self.transport.?.syncGroup(
            self.config.group_id,
            self.generation_id,
            self.member_id,
            assigns.items,
        );
        defer self.allocator.free(received);
        if (received.len > 0) {
            if (my_bytes) |owned| self.allocator.free(owned);
            return try self.allocator.dupe(u8, received);
        }
        return my_bytes orelse try self.allocator.alloc(u8, 0);
    }

    fn applyAssignmentBytes(self: *Self, bytes: []const u8) !void {
        self.clearAssignments();
        if (bytes.len == 0) return;
        var parsed = try KafkaWireFormat.parseMemberAssignment(self.allocator, bytes);
        defer parsed.deinit(self.allocator);
        for (parsed.items) |tp| {
            const topic_key = try self.allocator.dupe(u8, tp.topic);
            errdefer self.allocator.free(topic_key);
            const parts = try self.allocator.dupe(i32, tp.partitions);
            errdefer self.allocator.free(parts);
            try self.assigned.put(topic_key, parts);
            for (parts) |p| {
                if (self.getOffset(topic_key, p) == null) {
                    try self.putOffset(topic_key, p, 0);
                }
            }
        }
    }

    fn partitionsFor(self: *Self, topic: []const u8) []const i32 {
        if (self.assigned.get(topic)) |p| return p;
        return &[_]i32{0};
    }

    fn clearAssignments(self: *Self) void {
        var it = self.assigned.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.assigned.clearRetainingCapacity();
    }

    fn putOffset(self: *Self, topic: []const u8, partition: i32, offset: i64) !void {
        var key_buf: [512]u8 = undefined;
        const key = try offsetKeyBuf(&key_buf, topic, partition);
        const gop = try self.offsets.getOrPut(key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
        }
        gop.value_ptr.* = offset;
    }

    fn removeOffsetsForTopic(self: *Self, topic: []const u8) void {
        var doomed: [64][]const u8 = undefined;
        var n: usize = 0;
        var it = self.offsets.keyIterator();
        while (it.next()) |k| {
            if (n >= doomed.len) break;
            if (std.mem.startsWith(u8, k.*, topic) and k.*.len > topic.len and k.*[topic.len] == 0x1f) {
                doomed[n] = k.*;
                n += 1;
            }
        }
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (self.offsets.fetchRemove(doomed[i])) |rem| {
                self.allocator.free(rem.key);
            }
        }
    }

    fn commitBroker(self: *Self, topic: []const u8, partition: i32, offset: i64) !void {
        if (self.config.offline) return;
        if (self.config.group_id.len == 0) return;
        try self.ensureTransport();
        try self.transport.?.offsetCommit(
            self.config.group_id,
            self.generation_id,
            self.member_id,
            topic,
            partition,
            offset,
            "",
        );
    }

    fn ensureTransport(self: *Self) !void {
        if (self.transport != null) return;
        const io = self.io orelse return error.IoRequired;
        var t = try RobustMQTransport.init(self.allocator, io, self.config.bootstrap_servers, self.config.client_id);
        errdefer t.deinit();
        try t.connect();
        self.transport = t;
    }
};

fn offsetKeyBuf(buf: []u8, topic: []const u8, partition: i32) ![]u8 {
    return try std.fmt.bufPrint(buf, "{s}\x1f{d}", .{ topic, partition });
}

pub const KafkaEventBridge = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    producer: *KafkaProducer,
    consumer: *KafkaConsumer,

    pub fn init(allocator: std.mem.Allocator, producer: *KafkaProducer, consumer: *KafkaConsumer) Self {
        return .{ .allocator = allocator, .producer = producer, .consumer = consumer };
    }

    pub fn publishEvent(self: *Self, topic: []const u8, payload: []const u8) !void {
        try self.producer.send(.{
            .topic = topic,
            .key = null,
            .value = payload,
            .headers = &.{},
            .timestamp = nowSeconds(),
        });
    }

    pub fn bridgeTopic(self: *Self, topic: []const u8, on_event: *const fn ([]const u8) void) !void {
        const Store = struct {
            var cb: *const fn ([]const u8) void = undefined;
            fn handler(msg: KafkaMessage) void {
                cb(msg.value);
            }
        };
        Store.cb = on_event;
        try self.consumer.subscribe(topic, Store.handler);
    }
};

/// Kafka wire protocol builders (non-flexible headers; Produce/Fetch v7).
pub const KafkaWireFormat = struct {
    const api_produce: i16 = 0;
    const api_fetch: i16 = 1;
    const api_offset_commit: i16 = 8;
    const api_offset_fetch: i16 = 9;
    const api_join_group: i16 = 11;
    const api_heartbeat: i16 = 12;
    const api_leave_group: i16 = 13;
    const api_sync_group: i16 = 14;
    const api_versions: i16 = 18;

    pub const GroupAssignment = struct {
        member_id: []const u8,
        assignment: []const u8,
    };

    pub const JoinGroupMember = struct {
        member_id: []u8,
        metadata: []u8,
    };

    pub const JoinGroupResult = struct {
        generation_id: i32,
        protocol: []u8,
        leader_id: []u8,
        member_id: []u8,
        members: []JoinGroupMember,

        pub fn isLeader(self: JoinGroupResult) bool {
            return std.mem.eql(u8, self.member_id, self.leader_id);
        }

        pub fn deinit(self: *JoinGroupResult, allocator: std.mem.Allocator) void {
            allocator.free(self.protocol);
            allocator.free(self.leader_id);
            allocator.free(self.member_id);
            for (self.members) |m| {
                allocator.free(m.member_id);
                allocator.free(m.metadata);
            }
            allocator.free(self.members);
            self.* = undefined;
        }
    };

    pub fn buildApiVersionsRequest(allocator: std.mem.Allocator, correlation_id: i32, client_id: []const u8) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_versions, 1, correlation_id, client_id);
        // ApiVersionsRequest v1 body empty for basic handshake
        return buf.toOwnedSlice(allocator);
    }

    pub fn buildProduceRequest(
        allocator: std.mem.Allocator,
        topic: []const u8,
        partition: i32,
        key: ?[]const u8,
        value: []const u8,
        correlation_id: i32,
        client_id: []const u8,
        acks: i16,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_produce, 7, correlation_id, client_id);

        // transactional_id = null
        try appendI16(&buf, allocator, -1);
        try appendI16(&buf, allocator, acks);
        try appendI32(&buf, allocator, 30000); // timeout ms
        try appendI32(&buf, allocator, 1); // topic count
        try appendString(&buf, allocator, topic);
        try appendI32(&buf, allocator, 1); // partition count
        try appendI32(&buf, allocator, partition);

        const batch = try buildRecordBatch(allocator, key, value);
        defer allocator.free(batch);
        try appendI32(&buf, allocator, @intCast(batch.len));
        try buf.appendSlice(allocator, batch);

        return buf.toOwnedSlice(allocator);
    }

    pub fn buildFetchRequest(
        allocator: std.mem.Allocator,
        topic: []const u8,
        partition: i32,
        offset: i64,
        max_bytes: i32,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_fetch, 7, correlation_id, client_id);

        try appendI32(&buf, allocator, -1); // replica_id
        try appendI32(&buf, allocator, 500); // max_wait_ms
        try appendI32(&buf, allocator, 1); // min_bytes
        try appendI32(&buf, allocator, max_bytes); // max_bytes
        try appendI8(&buf, allocator, 0); // isolation_level
        try appendI32(&buf, allocator, 0); // session_id
        try appendI32(&buf, allocator, -1); // session_epoch
        try appendI32(&buf, allocator, 1); // topics
        try appendString(&buf, allocator, topic);
        try appendI32(&buf, allocator, 1); // partitions
        try appendI32(&buf, allocator, partition);
        try appendI32(&buf, allocator, -1); // current_leader_epoch
        try appendI64(&buf, allocator, offset);
        try appendI32(&buf, allocator, max_bytes);
        try appendI32(&buf, allocator, 0); // forgotten topics
        try appendString(&buf, allocator, ""); // rack_id

        return buf.toOwnedSlice(allocator);
    }

    /// OffsetCommitRequest v2 (non-flexible) — one topic / one partition.
    /// `generation_id` should come from JoinGroup; use -1 only for experiments.
    pub fn buildOffsetCommitRequest(
        allocator: std.mem.Allocator,
        group_id: []const u8,
        generation_id: i32,
        member_id: []const u8,
        topic: []const u8,
        partition: i32,
        offset: i64,
        metadata: []const u8,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_offset_commit, 2, correlation_id, client_id);
        try appendString(&buf, allocator, group_id);
        try appendI32(&buf, allocator, generation_id);
        try appendString(&buf, allocator, member_id);
        try appendI64(&buf, allocator, -1); // retention_time_ms: broker default
        try appendI32(&buf, allocator, 1); // topics
        try appendString(&buf, allocator, topic);
        try appendI32(&buf, allocator, 1); // partitions
        try appendI32(&buf, allocator, partition);
        try appendI64(&buf, allocator, offset);
        try appendString(&buf, allocator, metadata);
        return buf.toOwnedSlice(allocator);
    }

    pub fn checkOffsetCommitResponse(resp: []const u8, expected_corr: i32) !void {
        if (resp.len < 6) return error.InvalidResponse;
        const corr = readI32(resp[0..4]);
        if (corr != expected_corr) return error.CorrelationMismatch;
    }

    /// ConsumerProtocolSubscription (version 0) used as JoinGroup protocol metadata.
    pub fn buildConsumerProtocolMetadata(allocator: std.mem.Allocator, topics: []const []const u8) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendI16(&buf, allocator, 0); // version
        try appendI32(&buf, allocator, @intCast(topics.len));
        for (topics) |t| try appendString(&buf, allocator, t);
        try appendBytes(&buf, allocator, ""); // user_data
        return buf.toOwnedSlice(allocator);
    }

    /// ConsumerProtocolAssignment (version 0) — same partition list for every topic.
    pub fn buildMemberAssignment(
        allocator: std.mem.Allocator,
        topics: []const []const u8,
        partitions: []const i32,
    ) ![]u8 {
        var items = try allocator.alloc(TopicPartitions, topics.len);
        defer allocator.free(items);
        for (topics, 0..) |t, i| {
            items[i] = .{ .topic = t, .partitions = partitions };
        }
        return buildMemberAssignmentTopics(allocator, items);
    }

    pub const TopicPartitions = struct {
        topic: []const u8,
        partitions: []const i32,
    };

    pub const ParsedAssignment = struct {
        items: []TopicPartitions,
        /// Backing storage for owned topic names + partition slices.
        arena_owned: bool = true,

        pub fn deinit(self: *ParsedAssignment, allocator: std.mem.Allocator) void {
            for (self.items) |tp| {
                allocator.free(tp.topic);
                allocator.free(tp.partitions);
            }
            allocator.free(self.items);
            self.* = undefined;
        }
    };

    pub fn buildMemberAssignmentTopics(allocator: std.mem.Allocator, items: []const TopicPartitions) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendI16(&buf, allocator, 0); // version
        try appendI32(&buf, allocator, @intCast(items.len));
        for (items) |tp| {
            try appendString(&buf, allocator, tp.topic);
            try appendI32(&buf, allocator, @intCast(tp.partitions.len));
            for (tp.partitions) |p| try appendI32(&buf, allocator, p);
        }
        try appendBytes(&buf, allocator, ""); // user_data
        return buf.toOwnedSlice(allocator);
    }

    /// Classic Kafka range assignor for one topic: return `member_count` owned slices.
    /// Members are assumed already sorted lexicographically.
    pub fn rangeAssign(allocator: std.mem.Allocator, partition_count: i32, member_count: usize) ![][]i32 {
        if (member_count == 0) return error.InvalidMemberCount;
        if (partition_count < 1) return error.InvalidPartitionCount;
        const pc: usize = @intCast(partition_count);
        var out = try allocator.alloc([]i32, member_count);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |s| allocator.free(s);
            allocator.free(out);
        }
        const base = pc / member_count;
        const extra = pc % member_count;
        var next: i32 = 0;
        while (filled < member_count) : (filled += 1) {
            const n = base + if (filled < extra) @as(usize, 1) else 0;
            const slice = try allocator.alloc(i32, n);
            var j: usize = 0;
            while (j < n) : (j += 1) {
                slice[j] = next;
                next += 1;
            }
            out[filled] = slice;
        }
        return out;
    }

    pub fn parseMemberAssignment(allocator: std.mem.Allocator, bytes: []const u8) !ParsedAssignment {
        if (bytes.len < 6) return error.InvalidResponse;
        var off: usize = 0;
        _ = readI16(bytes[off..][0..2]); // version
        off += 2;
        if (off + 4 > bytes.len) return error.InvalidResponse;
        const topic_count = readI32(bytes[off..][0..4]);
        off += 4;
        if (topic_count < 0) return error.InvalidResponse;
        var items = try allocator.alloc(TopicPartitions, @intCast(topic_count));
        var filled: usize = 0;
        errdefer {
            for (items[0..filled]) |tp| {
                allocator.free(tp.topic);
                allocator.free(tp.partitions);
            }
            allocator.free(items);
        }
        while (filled < items.len) : (filled += 1) {
            const topic = try dupeString(allocator, bytes, &off);
            errdefer allocator.free(topic);
            if (off + 4 > bytes.len) return error.InvalidResponse;
            const pcount = readI32(bytes[off..][0..4]);
            off += 4;
            if (pcount < 0) return error.InvalidResponse;
            const parts = try allocator.alloc(i32, @intCast(pcount));
            errdefer allocator.free(parts);
            var pi: usize = 0;
            while (pi < parts.len) : (pi += 1) {
                if (off + 4 > bytes.len) return error.InvalidResponse;
                parts[pi] = readI32(bytes[off..][0..4]);
                off += 4;
            }
            items[filled] = .{ .topic = topic, .partitions = parts };
        }
        // skip user_data bytes
        if (off + 4 <= bytes.len) {
            const ulen = readI32(bytes[off..][0..4]);
            off += 4;
            if (ulen > 0) off += @intCast(ulen);
        }
        return .{ .items = items };
    }

    /// JoinGroupRequest v1 (non-flexible).
    pub fn buildJoinGroupRequest(
        allocator: std.mem.Allocator,
        group_id: []const u8,
        session_timeout_ms: i32,
        rebalance_timeout_ms: i32,
        member_id: []const u8,
        protocol_type: []const u8,
        protocol_name: []const u8,
        protocol_metadata: []const u8,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_join_group, 1, correlation_id, client_id);
        try appendString(&buf, allocator, group_id);
        try appendI32(&buf, allocator, session_timeout_ms);
        try appendI32(&buf, allocator, rebalance_timeout_ms);
        try appendString(&buf, allocator, member_id);
        try appendString(&buf, allocator, protocol_type);
        try appendI32(&buf, allocator, 1); // GroupProtocols count
        try appendString(&buf, allocator, protocol_name);
        try appendBytes(&buf, allocator, protocol_metadata);
        return buf.toOwnedSlice(allocator);
    }

    pub fn parseJoinGroupResponse(
        allocator: std.mem.Allocator,
        resp: []const u8,
        expected_corr: i32,
    ) !JoinGroupResult {
        if (resp.len < 8) return error.InvalidResponse;
        const corr = readI32(resp[0..4]);
        if (corr != expected_corr) return error.CorrelationMismatch;
        var off: usize = 4;
        // v1: throttle_time_ms
        if (off + 4 > resp.len) return error.InvalidResponse;
        off += 4;
        if (off + 2 > resp.len) return error.InvalidResponse;
        const err_code = readI16(resp[off..][0..2]);
        off += 2;
        if (err_code != 0) return error.BrokerError;
        if (off + 4 > resp.len) return error.InvalidResponse;
        const generation_id = readI32(resp[off..][0..4]);
        off += 4;
        const protocol = try dupeString(allocator, resp, &off);
        errdefer allocator.free(protocol);
        const leader_id = try dupeString(allocator, resp, &off);
        errdefer allocator.free(leader_id);
        const member_id = try dupeString(allocator, resp, &off);
        errdefer allocator.free(member_id);
        if (off + 4 > resp.len) return error.InvalidResponse;
        const member_count = readI32(resp[off..][0..4]);
        off += 4;
        if (member_count < 0) return error.InvalidResponse;
        var members = try allocator.alloc(JoinGroupMember, @intCast(member_count));
        var filled: usize = 0;
        errdefer {
            for (members[0..filled]) |m| {
                allocator.free(m.member_id);
                allocator.free(m.metadata);
            }
            allocator.free(members);
        }
        while (filled < members.len) : (filled += 1) {
            const mid = try dupeString(allocator, resp, &off);
            errdefer allocator.free(mid);
            const meta = try dupeBytes(allocator, resp, &off);
            members[filled] = .{ .member_id = mid, .metadata = meta };
        }
        return .{
            .generation_id = generation_id,
            .protocol = protocol,
            .leader_id = leader_id,
            .member_id = member_id,
            .members = members,
        };
    }

    /// SyncGroupRequest v0.
    pub fn buildSyncGroupRequest(
        allocator: std.mem.Allocator,
        group_id: []const u8,
        generation_id: i32,
        member_id: []const u8,
        assignments: []const GroupAssignment,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_sync_group, 0, correlation_id, client_id);
        try appendString(&buf, allocator, group_id);
        try appendI32(&buf, allocator, generation_id);
        try appendString(&buf, allocator, member_id);
        try appendI32(&buf, allocator, @intCast(assignments.len));
        for (assignments) |a| {
            try appendString(&buf, allocator, a.member_id);
            try appendBytes(&buf, allocator, a.assignment);
        }
        return buf.toOwnedSlice(allocator);
    }

    pub fn parseSyncGroupResponse(allocator: std.mem.Allocator, resp: []const u8, expected_corr: i32) ![]u8 {
        if (resp.len < 6) return error.InvalidResponse;
        const corr = readI32(resp[0..4]);
        if (corr != expected_corr) return error.CorrelationMismatch;
        const err_code = readI16(resp[4..6]);
        if (err_code != 0) return error.BrokerError;
        var off: usize = 6;
        return try dupeBytes(allocator, resp, &off);
    }

    /// HeartbeatRequest v0.
    pub fn buildHeartbeatRequest(
        allocator: std.mem.Allocator,
        group_id: []const u8,
        generation_id: i32,
        member_id: []const u8,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_heartbeat, 0, correlation_id, client_id);
        try appendString(&buf, allocator, group_id);
        try appendI32(&buf, allocator, generation_id);
        try appendString(&buf, allocator, member_id);
        return buf.toOwnedSlice(allocator);
    }

    pub fn checkHeartbeatResponse(resp: []const u8, expected_corr: i32) !void {
        if (resp.len < 6) return error.InvalidResponse;
        const corr = readI32(resp[0..4]);
        if (corr != expected_corr) return error.CorrelationMismatch;
        const err_code = readI16(resp[4..6]);
        if (err_code != 0) return error.BrokerError;
    }

    /// LeaveGroupRequest v0.
    pub fn buildLeaveGroupRequest(
        allocator: std.mem.Allocator,
        group_id: []const u8,
        member_id: []const u8,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_leave_group, 0, correlation_id, client_id);
        try appendString(&buf, allocator, group_id);
        try appendString(&buf, allocator, member_id);
        return buf.toOwnedSlice(allocator);
    }

    pub fn checkLeaveGroupResponse(resp: []const u8, expected_corr: i32) !void {
        if (resp.len < 6) return error.InvalidResponse;
        const corr = readI32(resp[0..4]);
        if (corr != expected_corr) return error.CorrelationMismatch;
        const err_code = readI16(resp[4..6]);
        if (err_code != 0) return error.BrokerError;
    }

    /// OffsetFetchRequest v1 — one topic / one partition.
    pub fn buildOffsetFetchRequest(
        allocator: std.mem.Allocator,
        group_id: []const u8,
        topic: []const u8,
        partition: i32,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_offset_fetch, 1, correlation_id, client_id);
        try appendString(&buf, allocator, group_id);
        try appendI32(&buf, allocator, 1); // topics
        try appendString(&buf, allocator, topic);
        try appendI32(&buf, allocator, 1); // partitions
        try appendI32(&buf, allocator, partition);
        return buf.toOwnedSlice(allocator);
    }

    /// OffsetFetchResponse v1 (non-flexible): topics → partitions → offset/metadata/error.
    pub fn parseOffsetFetchResponse(resp: []const u8, expected_corr: i32) !i64 {
        if (resp.len < 8) return error.InvalidResponse;
        const corr = readI32(resp[0..4]);
        if (corr != expected_corr) return error.CorrelationMismatch;
        var off: usize = 4;
        if (off + 4 > resp.len) return error.InvalidResponse;
        const topic_count = readI32(resp[off..][0..4]);
        off += 4;
        if (topic_count < 1) return error.InvalidResponse;
        // topic name
        if (off + 2 > resp.len) return error.InvalidResponse;
        const tlen = readI16(resp[off..][0..2]);
        off += 2;
        if (tlen < 0 or off + @as(usize, @intCast(tlen)) > resp.len) return error.InvalidResponse;
        off += @intCast(tlen);
        if (off + 4 > resp.len) return error.InvalidResponse;
        const part_count = readI32(resp[off..][0..4]);
        off += 4;
        if (part_count < 1) return error.InvalidResponse;
        if (off + 4 + 8 + 2 + 2 > resp.len) return error.InvalidResponse;
        off += 4; // partition id
        const offset = readI64(resp[off..][0..8]);
        off += 8;
        // metadata string
        if (off + 2 > resp.len) return error.InvalidResponse;
        const mlen = readI16(resp[off..][0..2]);
        off += 2;
        if (mlen > 0) {
            if (off + @as(usize, @intCast(mlen)) > resp.len) return error.InvalidResponse;
            off += @intCast(mlen);
        }
        if (off + 2 > resp.len) return error.InvalidResponse;
        const err_code = readI16(resp[off..][0..2]);
        if (err_code != 0) return error.BrokerError;
        return offset;
    }

    fn dupeString(allocator: std.mem.Allocator, buf: []const u8, off: *usize) ![]u8 {
        if (off.* + 2 > buf.len) return error.InvalidResponse;
        const len = readI16(buf[off.*..][0..2]);
        off.* += 2;
        if (len < 0) return try allocator.dupe(u8, "");
        if (off.* + @as(usize, @intCast(len)) > buf.len) return error.InvalidResponse;
        const s = try allocator.dupe(u8, buf[off.* .. off.* + @as(usize, @intCast(len))]);
        off.* += @intCast(len);
        return s;
    }

    fn dupeBytes(allocator: std.mem.Allocator, buf: []const u8, off: *usize) ![]u8 {
        if (off.* + 4 > buf.len) return error.InvalidResponse;
        const len = readI32(buf[off.*..][0..4]);
        off.* += 4;
        if (len < 0) return try allocator.dupe(u8, "");
        if (off.* + @as(usize, @intCast(len)) > buf.len) return error.InvalidResponse;
        const s = try allocator.dupe(u8, buf[off.* .. off.* + @as(usize, @intCast(len))]);
        off.* += @intCast(len);
        return s;
    }

    pub fn checkProduceResponse(resp: []const u8, expected_corr: i32) !void {
        if (resp.len < 6) return error.InvalidResponse;
        const corr = readI32(resp[0..4]);
        if (corr != expected_corr) return error.CorrelationMismatch;
        // Matching correlation is enough for smoke against RobustMQ; full topic/partition
        // error-code parse can be tightened once broker version matrix is locked.
    }

    /// Extract message values from a Fetch response by scanning for magic=2 record batches.
    /// Ported from zigmodu KafkaConnector — network path already exercised; this delivers payloads.
    pub fn parseFetchValues(allocator: std.mem.Allocator, resp: []const u8) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |v| allocator.free(v);
            out.deinit(allocator);
        }
        var i: usize = 0;
        while (i + 22 < resp.len) : (i += 1) {
            if (resp[i] != 2) continue;
            if (i < 16) continue;
            const batch_start = i - 16;
            if (batch_start + 21 > resp.len) continue;
            const length = readI32(resp[batch_start + 8 ..][0..4]);
            if (length <= 0 or length > 16 * 1024 * 1024) continue;
            const batch_end = batch_start + 12 + @as(usize, @intCast(length));
            if (batch_end > resp.len) continue;
            const values = parseRecordBatchValues(allocator, resp[batch_start..batch_end]) catch continue;
            defer {
                for (values) |v| allocator.free(v);
                allocator.free(values);
            }
            for (values) |v| {
                try out.append(allocator, try allocator.dupe(u8, v));
            }
            i = batch_end -| 1;
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Decode RecordBatch (magic=2) values (Produce layout).
    pub fn parseRecordBatchValues(allocator: std.mem.Allocator, batch: []const u8) ![][]const u8 {
        if (batch.len < 22) return error.InvalidRecordBatch;
        if (batch[16] != 2) return error.UnsupportedMagic;
        const body = batch[21..];
        if (body.len < 40) return try allocator.alloc([]const u8, 0);
        var off: usize = 40;
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |v| allocator.free(v);
            out.deinit(allocator);
        }
        while (off < body.len) {
            const rec_len, const n1 = try readVarint(body[off..]);
            off += n1;
            if (rec_len <= 0 or off + @as(usize, @intCast(rec_len)) > body.len) break;
            const rec = body[off .. off + @as(usize, @intCast(rec_len))];
            off += @intCast(rec_len);
            var roff: usize = 1;
            _, const n2 = try readVarint(rec[roff..]);
            roff += n2;
            _, const n3 = try readVarint(rec[roff..]);
            roff += n3;
            const key_len, const n4 = try readVarint(rec[roff..]);
            roff += n4;
            if (key_len >= 0) {
                if (roff + @as(usize, @intCast(key_len)) > rec.len) break;
                roff += @intCast(key_len);
            }
            const val_len, const n5 = try readVarint(rec[roff..]);
            roff += n5;
            if (val_len < 0 or roff + @as(usize, @intCast(val_len)) > rec.len) break;
            const val = try allocator.dupe(u8, rec[roff .. roff + @as(usize, @intCast(val_len))]);
            try out.append(allocator, val);
        }
        return try out.toOwnedSlice(allocator);
    }

    fn readVarint(buf: []const u8) !struct { i32, usize } {
        var result: u32 = 0;
        var shift: u5 = 0;
        var i: usize = 0;
        while (i < buf.len and i < 5) : (i += 1) {
            const b = buf[i];
            result |= @as(u32, b & 0x7f) << shift;
            if ((b & 0x80) == 0) {
                const decoded: i32 = @as(i32, @bitCast(result >> 1)) ^ -@as(i32, @intCast(result & 1));
                return .{ decoded, i + 1 };
            }
            shift += 7;
        }
        return error.InvalidVarint;
    }

    pub fn buildProduceRequestLegacy(
        allocator: std.mem.Allocator,
        topic: []const u8,
        partition: i32,
        key: ?[]const u8,
        value: []const u8,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]const u8 {
        return buildProduceRequest(allocator, topic, partition, key, value, correlation_id, client_id, 1);
    }

    fn appendRequestHeader(
        buf: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        api_key: i16,
        api_version: i16,
        correlation_id: i32,
        client_id: []const u8,
    ) !void {
        try appendI16(buf, allocator, api_key);
        try appendI16(buf, allocator, api_version);
        try appendI32(buf, allocator, correlation_id);
        try appendString(buf, allocator, client_id);
    }

    fn buildRecordBatch(allocator: std.mem.Allocator, key: ?[]const u8, value: []const u8) ![]u8 {
        var records = std.ArrayList(u8).empty;
        defer records.deinit(allocator);
        try appendKafkaRecord(&records, allocator, key, value);

        // Attributes through records (CRC covers from attributes to end)
        var body = std.ArrayList(u8).empty;
        defer body.deinit(allocator);
        try appendI16(&body, allocator, 0); // attributes
        try appendI32(&body, allocator, 0); // last_offset_delta
        const ts: i64 = nowMillis();
        try appendI64(&body, allocator, ts); // first_timestamp
        try appendI64(&body, allocator, ts); // max_timestamp
        try appendI64(&body, allocator, -1); // producer_id
        try appendI16(&body, allocator, -1); // producer_epoch
        try appendI32(&body, allocator, -1); // base_sequence
        try appendI32(&body, allocator, 1); // records count
        try body.appendSlice(allocator, records.items);

        // Kafka message CRC is CRC-32C (Castagnoli / ISCSI).
        // Zig renamed `Crc32Iscsi` → `@"CRC-32/ISCSI"` in 0.17-dev ~1422.
        const Crc32c = if (@hasDecl(std.hash.crc, "Crc32Iscsi"))
            std.hash.crc.Crc32Iscsi
        else
            std.hash.crc.@"CRC-32/ISCSI";
        const crc = Crc32c.hash(body.items);

        var batch = std.ArrayList(u8).empty;
        errdefer batch.deinit(allocator);
        try appendI64(&batch, allocator, 0); // base_offset
        // length = remaining after this field: partition_leader_epoch(4)+magic(1)+crc(4)+body
        const length: i32 = @intCast(4 + 1 + 4 + body.items.len);
        try appendI32(&batch, allocator, length);
        try appendI32(&batch, allocator, -1); // partition_leader_epoch
        try appendI8(&batch, allocator, 2); // magic
        try appendI32(&batch, allocator, @bitCast(crc));
        try batch.appendSlice(allocator, body.items);
        return batch.toOwnedSlice(allocator);
    }

    fn appendKafkaRecord(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, key: ?[]const u8, value: []const u8) !void {
        var rec = std.ArrayList(u8).empty;
        defer rec.deinit(allocator);
        try appendI8(&rec, allocator, 0); // attributes
        try appendVarint(&rec, allocator, 0); // timestamp_delta
        try appendVarint(&rec, allocator, 0); // offset_delta
        if (key) |k| {
            try appendVarint(&rec, allocator, @intCast(k.len));
            try rec.appendSlice(allocator, k);
        } else {
            try appendVarint(&rec, allocator, -1);
        }
        try appendVarint(&rec, allocator, @intCast(value.len));
        try rec.appendSlice(allocator, value);
        try appendVarint(&rec, allocator, 0); // headers count

        try appendVarint(buf, allocator, @intCast(rec.items.len));
        try buf.appendSlice(allocator, rec.items);
    }

    fn appendVarint(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i32) !void {
        // ZigZag + unsigned varint (Kafka record encoding)
        const zz: u32 = @bitCast((value << 1) ^ (value >> 31));
        var n = zz;
        while (n >= 0x80) {
            try buf.append(allocator, @truncate((n & 0x7f) | 0x80));
            n >>= 7;
        }
        try buf.append(allocator, @truncate(n));
    }

    fn appendString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
        try appendI16(buf, allocator, @intCast(s.len));
        try buf.appendSlice(allocator, s);
    }

    fn appendBytes(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
        try appendI32(buf, allocator, @intCast(s.len));
        try buf.appendSlice(allocator, s);
    }

    fn appendI8(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i8) !void {
        try buf.append(allocator, @bitCast(v));
    }

    fn appendI16(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i16) !void {
        var b: [2]u8 = undefined;
        writeI16(&b, v);
        try buf.appendSlice(allocator, &b);
    }

    fn appendI32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i32) !void {
        var b: [4]u8 = undefined;
        writeI32(&b, v);
        try buf.appendSlice(allocator, &b);
    }

    fn appendI64(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i64) !void {
        const u: u64 = @bitCast(v);
        var b: [8]u8 = undefined;
        inline for (0..8) |i| {
            b[i] = @truncate(u >> @intCast((7 - i) * 8));
        }
        try buf.appendSlice(allocator, &b);
    }
};

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "KafkaProducer send and stats" {
    const allocator = std.testing.allocator;
    var producer = KafkaProducer.init(allocator, .{});
    defer producer.deinit();

    const msg = KafkaMessage{
        .topic = "orders.created",
        .key = null,
        .value = "{\"order_id\":123}",
        .headers = &.{},
        .timestamp = nowSeconds(),
    };

    try producer.send(msg);
    try producer.send(msg);

    const stats = producer.getTopicStats("orders.created").?;
    try std.testing.expectEqual(@as(u64, 2), stats.produced);
}

test "KafkaProducer send batch" {
    const allocator = std.testing.allocator;
    var producer = KafkaProducer.init(allocator, .{});
    defer producer.deinit();

    const messages = &[_]KafkaMessage{
        .{ .topic = "t1", .key = null, .value = "m1", .headers = &.{}, .timestamp = nowSeconds() },
        .{ .topic = "t2", .key = null, .value = "m2", .headers = &.{}, .timestamp = nowSeconds() },
    };

    try producer.sendBatch(messages);
    try std.testing.expectEqual(@as(u64, 1), producer.getTopicStats("t1").?.produced);
    try std.testing.expectEqual(@as(u64, 1), producer.getTopicStats("t2").?.produced);
}

test "KafkaConsumer subscribe" {
    const allocator = std.testing.allocator;
    var consumer = KafkaConsumer.init(allocator, .{});
    defer consumer.deinit();

    try consumer.subscribe("orders.events", struct {
        fn handle(_: KafkaMessage) void {}
    }.handle);

    const subs = try consumer.getSubscriptions();
    defer allocator.free(subs);

    try std.testing.expectEqual(@as(usize, 1), subs.len);
    try std.testing.expectEqualStrings("orders.events", subs[0]);
}

test "KafkaConsumer unsubscribe" {
    const allocator = std.testing.allocator;
    var consumer = KafkaConsumer.init(allocator, .{});
    defer consumer.deinit();

    try consumer.subscribe("test.topic", struct {
        fn h(_: KafkaMessage) void {}
    }.h);
    try std.testing.expectEqual(@as(usize, 1), consumer.subscriptions.count());

    consumer.unsubscribe("test.topic");
    try std.testing.expectEqual(@as(usize, 0), consumer.subscriptions.count());
}

test "KafkaEventBridge basic" {
    const allocator = std.testing.allocator;
    var producer = KafkaProducer.init(allocator, .{});
    defer producer.deinit();
    var consumer = KafkaConsumer.init(allocator, .{});
    defer consumer.deinit();

    var bridge = KafkaEventBridge.init(allocator, &producer, &consumer);

    try bridge.publishEvent("payment.events", "{\"status\":\"paid\"}");
    try std.testing.expectEqual(@as(u64, 1), producer.getTopicStats("payment.events").?.produced);
}

test "KafkaProducer config" {
    const config = KafkaProducerConfig{
        .bootstrap_servers = "127.0.0.1:9092",
        .client_id = "test-client",
        .acks = .all,
        .compression = .snappy,
    };

    try std.testing.expectEqualStrings("127.0.0.1:9092", config.bootstrap_servers);
    try std.testing.expectEqual(KafkaProducerConfig.Acks.all, config.acks);
}

test "KafkaConsumer config" {
    const config = KafkaConsumerConfig{
        .group_id = "test-group",
        .auto_offset_reset = "earliest",
        .max_poll_records = 100,
    };

    try std.testing.expectEqualStrings("test-group", config.group_id);
    try std.testing.expectEqual(@as(usize, 100), config.max_poll_records);
}

test "KafkaWireFormat produce request" {
    const allocator = std.testing.allocator;
    const payload = try KafkaWireFormat.buildProduceRequest(
        allocator,
        "orders",
        0,
        null,
        "hello",
        1,
        "zfinal",
        1,
    );
    defer allocator.free(payload);
    try std.testing.expect(payload.len > 20);
    // api_key = 0
    try std.testing.expectEqual(@as(u8, 0), payload[0]);
    try std.testing.expectEqual(@as(u8, 0), payload[1]);
}

test "KafkaWireFormat offset commit request" {
    const allocator = std.testing.allocator;
    const payload = try KafkaWireFormat.buildOffsetCommitRequest(
        allocator,
        "zfinal-group",
        -1,
        "",
        "orders",
        0,
        42,
        "",
        9,
        "zfinal",
    );
    defer allocator.free(payload);
    try std.testing.expect(payload.len > 20);
    // api_key = 8
    try std.testing.expectEqual(@as(u8, 0), payload[0]);
    try std.testing.expectEqual(@as(u8, 8), payload[1]);
}

test "KafkaWireFormat join group request" {
    const allocator = std.testing.allocator;
    const meta = try KafkaWireFormat.buildConsumerProtocolMetadata(allocator, &.{"orders"});
    defer allocator.free(meta);
    const payload = try KafkaWireFormat.buildJoinGroupRequest(
        allocator,
        "zfinal-group",
        45000,
        30000,
        "",
        "consumer",
        "range",
        meta,
        3,
        "zfinal",
    );
    defer allocator.free(payload);
    try std.testing.expect(payload.len > 20);
    // api_key = 11
    try std.testing.expectEqual(@as(u8, 0), payload[0]);
    try std.testing.expectEqual(@as(u8, 11), payload[1]);
}

test "KafkaWireFormat sync group and heartbeat request" {
    const allocator = std.testing.allocator;
    const assign = try KafkaWireFormat.buildMemberAssignment(allocator, &.{"orders"}, &.{0});
    defer allocator.free(assign);
    const sync = try KafkaWireFormat.buildSyncGroupRequest(
        allocator,
        "zfinal-group",
        1,
        "member-1",
        &.{.{ .member_id = "member-1", .assignment = assign }},
        4,
        "zfinal",
    );
    defer allocator.free(sync);
    try std.testing.expectEqual(@as(u8, 0), sync[0]);
    try std.testing.expectEqual(@as(u8, 14), sync[1]);

    const hb = try KafkaWireFormat.buildHeartbeatRequest(
        allocator,
        "zfinal-group",
        1,
        "member-1",
        5,
        "zfinal",
    );
    defer allocator.free(hb);
    try std.testing.expectEqual(@as(u8, 0), hb[0]);
    try std.testing.expectEqual(@as(u8, 12), hb[1]);

    const leave = try KafkaWireFormat.buildLeaveGroupRequest(
        allocator,
        "zfinal-group",
        "member-1",
        6,
        "zfinal",
    );
    defer allocator.free(leave);
    try std.testing.expectEqual(@as(u8, 0), leave[0]);
    try std.testing.expectEqual(@as(u8, 13), leave[1]);

    const ofetch = try KafkaWireFormat.buildOffsetFetchRequest(
        allocator,
        "zfinal-group",
        "orders",
        0,
        7,
        "zfinal",
    );
    defer allocator.free(ofetch);
    try std.testing.expectEqual(@as(u8, 0), ofetch[0]);
    try std.testing.expectEqual(@as(u8, 9), ofetch[1]);
}

test "KafkaWireFormat parseJoinGroupResponse v1" {
    const allocator = std.testing.allocator;
    // corr(4) + throttle(4) + err(2) + gen(4) + protocol + leader + member + members=1
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var tmp: [4]u8 = undefined;
    writeI32(&tmp, 99);
    try buf.appendSlice(allocator, &tmp);
    writeI32(&tmp, 0); // throttle
    try buf.appendSlice(allocator, &tmp);
    var t2: [2]u8 = undefined;
    writeI16(&t2, 0); // error
    try buf.appendSlice(allocator, &t2);
    writeI32(&tmp, 7); // generation
    try buf.appendSlice(allocator, &tmp);
    // protocol "range"
    writeI16(&t2, 5);
    try buf.appendSlice(allocator, &t2);
    try buf.appendSlice(allocator, "range");
    // leader "m1"
    writeI16(&t2, 2);
    try buf.appendSlice(allocator, &t2);
    try buf.appendSlice(allocator, "m1");
    // member "m1"
    writeI16(&t2, 2);
    try buf.appendSlice(allocator, &t2);
    try buf.appendSlice(allocator, "m1");
    writeI32(&tmp, 1); // members
    try buf.appendSlice(allocator, &tmp);
    writeI16(&t2, 2);
    try buf.appendSlice(allocator, &t2);
    try buf.appendSlice(allocator, "m1");
    writeI32(&tmp, 0); // empty metadata
    try buf.appendSlice(allocator, &tmp);

    var result = try KafkaWireFormat.parseJoinGroupResponse(allocator, buf.items, 99);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(i32, 7), result.generation_id);
    try std.testing.expect(result.isLeader());
    try std.testing.expectEqual(@as(usize, 1), result.members.len);
}

test "KafkaConsumer join offline is no-op" {
    const allocator = std.testing.allocator;
    var consumer = KafkaConsumer.init(allocator, .{});
    defer consumer.deinit();
    try consumer.subscribe("t", struct {
        fn h(_: KafkaMessage) void {}
    }.h);
    try consumer.join(); // offline
    try std.testing.expectEqual(@as(i32, -1), consumer.generation_id);
}

test "KafkaConsumer commitLocal requires subscribe" {
    const allocator = std.testing.allocator;
    var consumer = KafkaConsumer.init(allocator, .{});
    defer consumer.deinit();
    try std.testing.expectError(error.NotSubscribed, consumer.commitLocal("t", 1));
    try consumer.subscribe("t", struct {
        fn h(_: KafkaMessage) void {}
    }.h);
    try consumer.commitLocal("t", 7);
    try std.testing.expectEqual(@as(i64, 7), consumer.getOffset("t", 0).?);
}

test "KafkaWireFormat rangeAssign classic distribution" {
    const allocator = std.testing.allocator;
    // 3 partitions, 2 members → [0,1] and [2]
    const a = try KafkaWireFormat.rangeAssign(allocator, 3, 2);
    defer {
        for (a) |s| allocator.free(s);
        allocator.free(a);
    }
    try std.testing.expectEqual(@as(usize, 2), a.len);
    try std.testing.expectEqualSlices(i32, &.{ 0, 1 }, a[0]);
    try std.testing.expectEqualSlices(i32, &.{2}, a[1]);

    // 4 partitions, 2 members → [0,1] and [2,3]
    const b = try KafkaWireFormat.rangeAssign(allocator, 4, 2);
    defer {
        for (b) |s| allocator.free(s);
        allocator.free(b);
    }
    try std.testing.expectEqualSlices(i32, &.{ 0, 1 }, b[0]);
    try std.testing.expectEqualSlices(i32, &.{ 2, 3 }, b[1]);
}

test "KafkaWireFormat parseMemberAssignment roundtrip" {
    const allocator = std.testing.allocator;
    const bytes = try KafkaWireFormat.buildMemberAssignmentTopics(allocator, &.{
        .{ .topic = "orders", .partitions = &.{ 0, 1 } },
        .{ .topic = "payments", .partitions = &.{2} },
    });
    defer allocator.free(bytes);
    var parsed = try KafkaWireFormat.parseMemberAssignment(allocator, bytes);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), parsed.items.len);
    try std.testing.expectEqualStrings("orders", parsed.items[0].topic);
    try std.testing.expectEqualSlices(i32, &.{ 0, 1 }, parsed.items[0].partitions);
    try std.testing.expectEqualStrings("payments", parsed.items[1].topic);
    try std.testing.expectEqualSlices(i32, &.{2}, parsed.items[1].partitions);
}

test "KafkaWireFormat parseFetchValues finds embedded batch" {
    const allocator = std.testing.allocator;
    // Build a produce request which embeds a RecordBatch, then scan it.
    const payload = try KafkaWireFormat.buildProduceRequest(
        allocator,
        "t",
        0,
        null,
        "fetch-me",
        7,
        "zfinal",
        1,
    );
    defer allocator.free(payload);
    const values = try KafkaWireFormat.parseFetchValues(allocator, payload);
    defer {
        for (values) |v| allocator.free(v);
        allocator.free(values);
    }
    try std.testing.expect(values.len >= 1);
    try std.testing.expectEqualStrings("fetch-me", values[0]);
}

test "parseBootstrap RobustMQ default form" {
    const host, const port = try parseBootstrap("127.0.0.1:9092");
    try std.testing.expectEqualStrings("127.0.0.1", host);
    try std.testing.expectEqual(@as(u16, 9092), port);

    const h2, const p2 = try parseBootstrap("broker:9092,broker2:9092");
    try std.testing.expectEqualStrings("broker", h2);
    try std.testing.expectEqual(@as(u16, 9092), p2);
}

test "RobustMQ live produce" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const url = if (std.c.getenv("ROBUSTMQ_URL")) |p| std.mem.span(p) else if (std.c.getenv("KAFKA_BOOTSTRAP")) |p| std.mem.span(p) else null;
    if (url == null or url.?.len == 0) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var producer = KafkaProducer.initWithIo(allocator, std.testing.io, .{
        .bootstrap_servers = url.?,
        .client_id = "zfinal-test",
    });
    defer producer.deinit();

    try producer.send(.{
        .topic = "zfinal.robustmq.smoke",
        .key = "k1",
        .value = "hello-robustmq",
        .headers = &.{},
        .timestamp = nowSeconds(),
    });
    try std.testing.expectEqual(@as(u64, 1), producer.getTopicStats("zfinal.robustmq.smoke").?.produced);
}

/// Queue-shaped façade over RobustMQ / Kafka (subject → topic), symmetric to
/// `QueueClient` (memory) and `QueueNatsClient` (NATS).
pub const QueueRobustMQClient = struct {
    allocator: std.mem.Allocator,
    producer: KafkaProducer,

    /// Online: uses framework `io_instance.io`. Bootstrap e.g. `127.0.0.1:9092`.
    pub fn connect(allocator: std.mem.Allocator, bootstrap: []const u8) QueueRobustMQClient {
        return .{
            .allocator = allocator,
            .producer = KafkaProducer.initWithIo(allocator, io_instance.io, .{
                .bootstrap_servers = bootstrap,
                .client_id = "zfinal-robustmq",
            }),
        };
    }

    /// Offline producer (unit tests / dry-run without broker).
    pub fn connectOffline(allocator: std.mem.Allocator) QueueRobustMQClient {
        return .{
            .allocator = allocator,
            .producer = KafkaProducer.init(allocator, .{}),
        };
    }

    pub fn deinit(self: *QueueRobustMQClient) void {
        self.producer.deinit();
    }

    pub fn close(self: *QueueRobustMQClient) void {
        self.producer.close();
    }

    /// Publish `data` to Kafka topic named `subject` (RobustMQ multi-protocol topic).
    pub fn publish(self: *QueueRobustMQClient, subject: []const u8, data: []const u8) !void {
        try self.producer.send(.{
            .topic = subject,
            .key = null,
            .value = data,
            .headers = &.{},
            .timestamp = nowSeconds(),
        });
    }

    pub fn publishKeyed(self: *QueueRobustMQClient, subject: []const u8, key: []const u8, data: []const u8) !void {
        try self.producer.send(.{
            .topic = subject,
            .key = key,
            .value = data,
            .headers = &.{},
            .timestamp = nowSeconds(),
        });
    }

    pub fn getTopicStats(self: *QueueRobustMQClient, topic: []const u8) ?KafkaProducer.TopicStats {
        return self.producer.getTopicStats(topic);
    }
};

test "QueueRobustMQClient offline publish" {
    const a = std.testing.allocator;
    var q = QueueRobustMQClient.connectOffline(a);
    defer q.deinit();
    try q.publish("orders.created", "{\"id\":1}");
    try q.publishKeyed("orders.created", "1", "{\"id\":1}");
    try std.testing.expectEqual(@as(u64, 2), q.getTopicStats("orders.created").?.produced);
}
