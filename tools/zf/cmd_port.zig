//! `zf g port <store|cache|bus>` — L2/L3 ports from progressive_architecture.md
const std = @import("std");
const zf_cfg = @import("zf_cfg");
const zf_shared = @import("zf_shared.zig");

const safeWrite = zf_shared.safeWrite;
const appendJsonString = zf_shared.appendJsonString;

/// Generate `src/ports/{name}.zig` (+ matching `src/adapters/*` stubs).
/// `name` must be `store`, `cache`, or `bus`.
pub fn generatePort(allocator: std.mem.Allocator, name: []const u8, force: bool, json_mode: bool) !void {
    const kind = parsePortKind(name) orelse {
        std.debug.print("Error: unknown port '{s}'. Use: store, cache, bus\n", .{name});
        std.debug.print("See doc/progressive_architecture.md (L2/L3 ports).\n", .{});
        return;
    };

    try zf_shared.ensureDir(allocator, "src/ports");
    try zf_shared.ensureDir(allocator, "src/adapters");

    const port_path = try std.fmt.allocPrint(allocator, "src/ports/{s}.zig", .{@tagName(kind)});
    defer allocator.free(port_path);
    const port_src = portSource(kind);
    try safeWrite(allocator, port_path, port_src, force);

    // Adapter stubs (memory + one production-shaped adapter)
    const adapters = adapterSpecs(kind);
    for (adapters) |a| {
        const path = try std.fmt.allocPrint(allocator, "src/adapters/{s}.zig", .{a.file});
        defer allocator.free(path);
        try safeWrite(allocator, path, a.source, force);
    }

    std.debug.print("\nNext: wire in main.zig — inject ports into services (see doc/progressive_architecture.md).\n", .{});
    std.debug.print("Edit only // ── ai-edit-zone blocks.\n", .{});

    if (json_mode) {
        try emitManifest(allocator, kind, port_path, adapters);
    }
}

const PortKind = enum { store, cache, bus };

fn parsePortKind(name: []const u8) ?PortKind {
    if (std.mem.eql(u8, name, "store")) return .store;
    if (std.mem.eql(u8, name, "cache")) return .cache;
    if (std.mem.eql(u8, name, "bus")) return .bus;
    return null;
}

const AdapterSpec = struct { file: []const u8, source: []const u8 };

fn adapterSpecs(kind: PortKind) []const AdapterSpec {
    return switch (kind) {
        .store => &[_]AdapterSpec{
            .{ .file = "memory_store", .source = memory_store_src },
            .{ .file = "pg_store", .source = pg_store_src },
        },
        .cache => &[_]AdapterSpec{
            .{ .file = "memory_cache", .source = memory_cache_src },
            .{ .file = "redis_cache", .source = redis_cache_src },
        },
        .bus => &[_]AdapterSpec{
            .{ .file = "memory_bus", .source = memory_bus_src },
            .{ .file = "nats_bus", .source = nats_bus_src },
            .{ .file = "robustmq_bus", .source = robustmq_bus_src },
        },
    };
}

fn portSource(kind: PortKind) []const u8 {
    return switch (kind) {
        .store => store_port_src,
        .cache => cache_port_src,
        .bus => bus_port_src,
    };
}

fn emitManifest(allocator: std.mem.Allocator, kind: PortKind, port_path: []const u8, adapters: []const AdapterSpec) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\n");
    try buf.appendSlice(allocator, "  \"$schema\": \"https://zfinal.dev/schemas/manifest-1.json\",\n");
    try buf.appendSlice(allocator, "  \"version\": \"");
    try buf.appendSlice(allocator, zf_cfg.semver);
    try buf.appendSlice(allocator, "\",\n");
    try buf.appendSlice(allocator, "  \"generator\": \"zf g port\",\n");
    try buf.appendSlice(allocator, "  \"type\": \"port\",\n");
    try buf.appendSlice(allocator, "  \"name\": \"");
    try appendJsonString(allocator, &buf, @tagName(kind));
    try buf.appendSlice(allocator, "\",\n");
    try buf.appendSlice(allocator, "  \"file\": \"");
    try appendJsonString(allocator, &buf, port_path);
    try buf.appendSlice(allocator, "\",\n");
    try buf.appendSlice(allocator, "  \"adapters\": [\n");
    for (adapters, 0..) |a, i| {
        if (i > 0) try buf.appendSlice(allocator, ",\n");
        try buf.appendSlice(allocator, "    \"src/adapters/");
        try appendJsonString(allocator, &buf, a.file);
        try buf.appendSlice(allocator, ".zig\"");
    }
    try buf.appendSlice(allocator, "\n  ],\n");
    try buf.appendSlice(allocator,
        \\  "ai_edit_zones": [
        \\    { "file": "ports", "markers": ["// ── ai-edit-zone: port ops"], "purpose": "extend port surface" },
        \\    { "file": "adapters", "markers": ["// ── ai-edit-zone: adapter impl"], "purpose": "wire zfinal.DB / Redis / Queue*" }
        \\  ],
        \\  "next_steps": [
        \\    "Inject port into service via comptime Store/Cache/Bus params",
        \\    "Assemble adapters in main.zig (L2/L3)",
        \\    "Run: zf check && zig build test"
        \\  ]
        \\}
        \\
    );
    var out = std.Io.File.stdout();
    try out.writeStreamingAll(zf_shared.io, buf.items);
}

// ── templates ──────────────────────────────────────────────────────────────

const store_port_src =
    \\//! Read/write store port (L2+). Services depend on this — not on a global *DB.
    \\//! See doc/progressive_architecture.md
    \\const std = @import("std");
    \\
    \\/// Minimal store surface. Replace `Row` / methods in the ai-edit-zone for your domain.
    \\pub const Store = struct {
    \\    ptr: *anyopaque,
    \\    vtable: *const VTable,
    \\
    \\    pub const VTable = struct {
    \\        // ── ai-edit-zone: port ops ────────────────────────────────
    \\        exec: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, sql: []const u8) anyerror!void,
    \\        // ── end ai-edit-zone ──────────────────────────────────────
    \\    };
    \\
    \\    pub fn exec(self: Store, allocator: std.mem.Allocator, sql: []const u8) !void {
    \\        return self.vtable.exec(self.ptr, allocator, sql);
    \\    }
    \\};
    \\
;

const cache_port_src =
    \\//! Cache port (L2+). Swap memory ↔ Redis without touching services.
    \\//! See doc/progressive_architecture.md
    \\const std = @import("std");
    \\
    \\pub const Cache = struct {
    \\    ptr: *anyopaque,
    \\    vtable: *const VTable,
    \\
    \\    pub const VTable = struct {
    \\        // ── ai-edit-zone: port ops ────────────────────────────────
    \\        get: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?[]u8,
    \\        set: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, value: []const u8, ttl_s: u64) anyerror!void,
    \\        invalidate: *const fn (ptr: *anyopaque, key: []const u8) void,
    \\        // ── end ai-edit-zone ──────────────────────────────────────
    \\    };
    \\
    \\    pub fn get(self: Cache, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    \\        return self.vtable.get(self.ptr, allocator, key);
    \\    }
    \\    pub fn set(self: Cache, allocator: std.mem.Allocator, key: []const u8, value: []const u8, ttl_s: u64) !void {
    \\        return self.vtable.set(self.ptr, allocator, key, value, ttl_s);
    \\    }
    \\    pub fn invalidate(self: Cache, key: []const u8) void {
    \\        self.vtable.invalidate(self.ptr, key);
    \\    }
    \\};
    \\
;

const bus_port_src =
    \\//! Message bus port (L3). Publish only — consume via worker / NATS / KafkaConsumer.
    \\//! L3 multi-instance consume: prefer QueueNatsClient (see doc/robustmq.md).
    \\//! See doc/progressive_architecture.md
    \\const std = @import("std");
    \\
    \\pub const Bus = struct {
    \\    ptr: *anyopaque,
    \\    vtable: *const VTable,
    \\
    \\    pub const VTable = struct {
    \\        // ── ai-edit-zone: port ops ────────────────────────────────
    \\        publish: *const fn (ptr: *anyopaque, subject: []const u8, payload: []const u8) anyerror!void,
    \\        // ── end ai-edit-zone ──────────────────────────────────────
    \\    };
    \\
    \\    pub fn publish(self: Bus, subject: []const u8, payload: []const u8) !void {
    \\        return self.vtable.publish(self.ptr, subject, payload);
    \\    }
    \\};
    \\
;

const memory_store_src =
    \\//! In-process store adapter for tests / L0.
    \\const std = @import("std");
    \\const ports = @import("../ports/store.zig");
    \\
    \\pub const MemoryStore = struct {
    \\    allocator: std.mem.Allocator,
    \\
    \\    pub fn port(self: *MemoryStore) ports.Store {
    \\        return .{ .ptr = self, .vtable = &vtable };
    \\    }
    \\
    \\    // ── ai-edit-zone: adapter impl ───────────────────────────────
    \\    fn execImpl(ptr: *anyopaque, allocator: std.mem.Allocator, sql: []const u8) anyerror!void {
    \\        _ = ptr;
    \\        _ = allocator;
    \\        _ = sql;
    \\        // no-op for smoke; replace with real buffering if needed
    \\    }
    \\    // ── end ai-edit-zone ─────────────────────────────────────────
    \\
    \\    const vtable = ports.Store.VTable{ .exec = execImpl };
    \\};
    \\
;

const pg_store_src =
    \\//! PostgreSQL / SQLite store adapter — wire your `*zfinal.DB` or pool here.
    \\const std = @import("std");
    \\const ports = @import("../ports/store.zig");
    \\
    \\pub const PgStore = struct {
    \\    // ── ai-edit-zone: adapter impl ───────────────────────────────
    \\    // db: *zfinal.DB,
    \\
    \\    pub fn port(self: *PgStore) ports.Store {
    \\        return .{ .ptr = self, .vtable = &vtable };
    \\    }
    \\
    \\    fn execImpl(ptr: *anyopaque, allocator: std.mem.Allocator, sql: []const u8) anyerror!void {
    \\        _ = ptr;
    \\        _ = allocator;
    \\        _ = sql;
    \\        return error.NotWired; // inject *DB and call db.exec
    \\    }
    \\    // ── end ai-edit-zone ─────────────────────────────────────────
    \\
    \\    const vtable = ports.Store.VTable{ .exec = execImpl };
    \\};
    \\
;

const memory_cache_src =
    \\//! Process-local cache (L0–L1). Do not use as sole session store under L2 multi-instance.
    \\const std = @import("std");
    \\const ports = @import("../ports/cache.zig");
    \\
    \\pub const MemoryCache = struct {
    \\    map: std.StringHashMapUnmanaged([]u8) = .{},
    \\    allocator: std.mem.Allocator,
    \\
    \\    pub fn deinit(self: *MemoryCache) void {
    \\        var it = self.map.iterator();
    \\        while (it.next()) |e| {
    \\            self.allocator.free(e.key_ptr.*);
    \\            self.allocator.free(e.value_ptr.*);
    \\        }
    \\        self.map.deinit(self.allocator);
    \\    }
    \\
    \\    pub fn port(self: *MemoryCache) ports.Cache {
    \\        return .{ .ptr = self, .vtable = &vtable };
    \\    }
    \\
    \\    // ── ai-edit-zone: adapter impl ───────────────────────────────
    \\    fn getImpl(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?[]u8 {
    \\        const self: *MemoryCache = @ptrCast(@alignCast(ptr));
    \\        const v = self.map.get(key) orelse return null;
    \\        return try allocator.dupe(u8, v);
    \\    }
    \\    fn setImpl(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, value: []const u8, ttl_s: u64) anyerror!void {
    \\        _ = ttl_s;
    \\        const self: *MemoryCache = @ptrCast(@alignCast(ptr));
    \\        _ = allocator;
    \\        const k = try self.allocator.dupe(u8, key);
    \\        errdefer self.allocator.free(k);
    \\        const v = try self.allocator.dupe(u8, value);
    \\        errdefer self.allocator.free(v);
    \\        if (try self.map.fetchPut(self.allocator, k, v)) |old| {
    \\            self.allocator.free(old.key);
    \\            self.allocator.free(old.value);
    \\        }
    \\    }
    \\    fn invalidateImpl(ptr: *anyopaque, key: []const u8) void {
    \\        const self: *MemoryCache = @ptrCast(@alignCast(ptr));
    \\        if (self.map.fetchRemove(key)) |kv| {
    \\            self.allocator.free(kv.key);
    \\            self.allocator.free(kv.value);
    \\        }
    \\    }
    \\    // ── end ai-edit-zone ─────────────────────────────────────────
    \\
    \\    const vtable = ports.Cache.VTable{
    \\        .get = getImpl,
    \\        .set = setImpl,
    \\        .invalidate = invalidateImpl,
    \\    };
    \\};
    \\
;

const redis_cache_src =
    \\//! Redis cache adapter stub — wire `zfinal.RedisClient` in the ai-edit-zone.
    \\const std = @import("std");
    \\const ports = @import("../ports/cache.zig");
    \\
    \\pub const RedisCache = struct {
    \\    // client: *zfinal.RedisClient,
    \\
    \\    pub fn port(self: *RedisCache) ports.Cache {
    \\        return .{ .ptr = self, .vtable = &vtable };
    \\    }
    \\
    \\    // ── ai-edit-zone: adapter impl ───────────────────────────────
    \\    fn getImpl(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?[]u8 {
    \\        _ = ptr;
    \\        _ = allocator;
    \\        _ = key;
    \\        return error.NotWired;
    \\    }
    \\    fn setImpl(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, value: []const u8, ttl_s: u64) anyerror!void {
    \\        _ = ptr;
    \\        _ = allocator;
    \\        _ = key;
    \\        _ = value;
    \\        _ = ttl_s;
    \\        return error.NotWired;
    \\    }
    \\    fn invalidateImpl(ptr: *anyopaque, key: []const u8) void {
    \\        _ = ptr;
    \\        _ = key;
    \\    }
    \\    // ── end ai-edit-zone ─────────────────────────────────────────
    \\
    \\    const vtable = ports.Cache.VTable{
    \\        .get = getImpl,
    \\        .set = setImpl,
    \\        .invalidate = invalidateImpl,
    \\    };
    \\};
    \\
;

const memory_bus_src =
    \\//! In-process bus via zfinal.QueueClient (L0–L2 tests).
    \\const std = @import("std");
    \\const ports = @import("../ports/bus.zig");
    \\
    \\pub const MemoryBus = struct {
    \\    // queue: *zfinal.QueueClient,
    \\
    \\    pub fn port(self: *MemoryBus) ports.Bus {
    \\        return .{ .ptr = self, .vtable = &vtable };
    \\    }
    \\
    \\    // ── ai-edit-zone: adapter impl ───────────────────────────────
    \\    fn publishImpl(ptr: *anyopaque, subject: []const u8, payload: []const u8) anyerror!void {
    \\        _ = ptr;
    \\        _ = subject;
    \\        _ = payload;
    \\        // Wire: try self.queue.publish(subject, payload);
    \\    }
    \\    // ── end ai-edit-zone ─────────────────────────────────────────
    \\
    \\    const vtable = ports.Bus.VTable{ .publish = publishImpl };
    \\};
    \\
;

const nats_bus_src =
    \\//! NATS bus adapter — preferred for L3 multi-instance consume (queue groups).
    \\//! See doc/nats.md + doc/robustmq.md
    \\const std = @import("std");
    \\const ports = @import("../ports/bus.zig");
    \\
    \\pub const NatsBus = struct {
    \\    // client: *zfinal.QueueNatsClient,
    \\
    \\    pub fn port(self: *NatsBus) ports.Bus {
    \\        return .{ .ptr = self, .vtable = &vtable };
    \\    }
    \\
    \\    // ── ai-edit-zone: adapter impl ───────────────────────────────
    \\    fn publishImpl(ptr: *anyopaque, subject: []const u8, payload: []const u8) anyerror!void {
    \\        _ = ptr;
    \\        _ = subject;
    \\        _ = payload;
    \\        return error.NotWired; // try self.client.publish(subject, payload);
    \\    }
    \\    // ── end ai-edit-zone ─────────────────────────────────────────
    \\
    \\    const vtable = ports.Bus.VTable{ .publish = publishImpl };
    \\};
    \\
;

const robustmq_bus_src =
    \\//! RobustMQ / Kafka publish adapter (L3). Consume: JoinGroup MVP or prefer NATS.
    \\//! See doc/robustmq.md
    \\const std = @import("std");
    \\const ports = @import("../ports/bus.zig");
    \\
    \\pub const RobustmqBus = struct {
    \\    // client: *zfinal.QueueRobustMQClient,
    \\
    \\    pub fn port(self: *RobustmqBus) ports.Bus {
    \\        return .{ .ptr = self, .vtable = &vtable };
    \\    }
    \\
    \\    // ── ai-edit-zone: adapter impl ───────────────────────────────
    \\    fn publishImpl(ptr: *anyopaque, subject: []const u8, payload: []const u8) anyerror!void {
    \\        _ = ptr;
    \\        _ = subject;
    \\        _ = payload;
    \\        return error.NotWired; // try self.client.publish(subject, payload);
    \\    }
    \\    // ── end ai-edit-zone ─────────────────────────────────────────
    \\
    \\    const vtable = ports.Bus.VTable{ .publish = publishImpl };
    \\};
    \\
;
