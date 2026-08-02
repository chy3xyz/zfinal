//! Lightweight multi-step approval chain (memory + optional SQLite pending queue).
//!
//! Policy callbacks decide each step (approve / reject / escalate-to-human).
//! Escalations land in a pending queue for `approval.resolve`. Skills:
//! `approval.submit` / `approval.list_pending` / `approval.resolve`.
//! Call `attachDb` to persist pending rows in `ai_approval_pending`
//! (`status`: 0=pending, 1=approved, 2=rejected).

const std = @import("std");
const SkillRegistry = @import("skill.zig").SkillRegistry;
const SkillContext = @import("skill.zig").SkillContext;
const ToolApproval = @import("agent.zig").ToolApproval;
const time_util = @import("time_util.zig");
const DB = @import("../db/db.zig").DB;
const SqlParam = @import("../db/sql_param.zig").SqlParam;

pub const ApprovalDecision = enum { approved, escalated, rejected };
pub const ApprovalStatus = enum { approved, pending_human, rejected };
/// Outcome of `ApprovalFlow.lookup` (memory pending / resolved ring / DB).
pub const ResolveStatus = enum { pending, approved, rejected, unknown };

pub const ApprovalStep = struct {
    name: []const u8,
};

pub const ApprovalEntry = struct {
    step: []const u8,
    decision: ApprovalDecision,
    note: []const u8 = "",
};

pub const ApprovalResult = struct {
    run_id: []const u8,
    subject: []const u8,
    amount: i64,
    status: ApprovalStatus,
    entries: []ApprovalEntry,

    pub fn deinit(self: *ApprovalResult, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        allocator.free(self.subject);
        for (self.entries) |e| {
            allocator.free(e.step);
            if (e.note.len > 0) allocator.free(e.note);
        }
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const DecidePolicyFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    subject: []const u8,
    amount: i64,
    step_index: usize,
    step_name: []const u8,
    request: []const u8,
    out_note: *[]const u8,
) anyerror!ApprovalDecision;

pub const PendingItem = struct {
    run_id: []const u8,
    subject: []const u8,
    amount: i64,
    request: []const u8,
    step_name: []const u8,
    created_at_ms: i64,
    tenant_id: ?i64 = null,
    /// Wall-clock deadline for SLA (ms). Null = no SLA tracked.
    deadline_ms: ?i64 = null,
};

const ResolvedItem = struct {
    run_id: []const u8,
    approved: bool,
};

pub const ResolveHookFn = *const fn (ctx: ?*anyopaque, run_id: []const u8, approved: bool) void;

pub const ApprovalFlow = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    policy: DecidePolicyFn,
    pending: std.ArrayList(PendingItem) = .empty,
    resolved: std.ArrayList(ResolvedItem) = .empty,
    seq: usize = 0,
    db: ?*DB = null,
    /// When set, escalations get `deadline_ms = now + default_sla_ms`.
    default_sla_ms: ?i64 = null,
    on_resolve: ?ResolveHookFn = null,
    on_resolve_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, policy: DecidePolicyFn) ApprovalFlow {
        return .{ .allocator = allocator, .io = io, .mutex = .init, .policy = policy };
    }

    pub fn deinit(self: *ApprovalFlow) void {
        for (self.pending.items) |p| freePending(self.allocator, p);
        self.pending.deinit(self.allocator);
        for (self.resolved.items) |r| self.allocator.free(r.run_id);
        self.resolved.deinit(self.allocator);
        self.* = undefined;
    }

    /// Persist pending queue to SQLite (`ai_approval_pending`). Idempotent migrate.
    pub fn attachDb(self: *ApprovalFlow, db: *DB) !void {
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS ai_approval_pending (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  run_id TEXT NOT NULL UNIQUE,
            \\  subject TEXT NOT NULL,
            \\  amount INTEGER NOT NULL,
            \\  request TEXT NOT NULL DEFAULT '',
            \\  step_name TEXT NOT NULL,
            \\  status INTEGER NOT NULL DEFAULT 0,
            \\  created_at_ms INTEGER NOT NULL,
            \\  tenant_id INTEGER,
            \\  deadline_ms INTEGER
            \\)
        );
        self.db = db;
    }

    pub fn submit(
        self: *ApprovalFlow,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        subject: []const u8,
        amount: i64,
        request: []const u8,
        steps: []const ApprovalStep,
    ) !ApprovalResult {
        self.mutex.lock(self.io) catch return error.LockFailed;
        self.seq += 1;
        const seq = self.seq;
        self.mutex.unlock(self.io);

        const run_id = try std.fmt.allocPrint(allocator, "ap-{d}", .{seq});
        errdefer allocator.free(run_id);

        var entries = std.ArrayList(ApprovalEntry).empty;
        errdefer {
            for (entries.items) |e| {
                allocator.free(e.step);
                if (e.note.len > 0) allocator.free(e.note);
            }
            entries.deinit(allocator);
        }

        var status: ApprovalStatus = .approved;
        for (steps, 0..) |step, idx| {
            var note: []const u8 = "";
            const decision = try self.policy(allocator, ctx, subject, amount, idx, step.name, request, &note);
            try entries.append(allocator, .{
                .step = try allocator.dupe(u8, step.name),
                .decision = decision,
                .note = note,
            });
            switch (decision) {
                .approved => {},
                .rejected => {
                    status = .rejected;
                    break;
                },
                .escalated => {
                    status = .pending_human;
                    const run_owned = try self.allocator.dupe(u8, run_id);
                    errdefer self.allocator.free(run_owned);
                    const subj_owned = try self.allocator.dupe(u8, subject);
                    errdefer self.allocator.free(subj_owned);
                    const req_owned = try self.allocator.dupe(u8, request);
                    errdefer self.allocator.free(req_owned);
                    const step_owned = try self.allocator.dupe(u8, step.name);
                    errdefer self.allocator.free(step_owned);
                    const now = time_util.nowMillis();
                    const deadline: ?i64 = if (self.default_sla_ms) |sla| now + sla else null;
                    try self.enqueuePending(.{
                        .run_id = run_owned,
                        .subject = subj_owned,
                        .amount = amount,
                        .request = req_owned,
                        .step_name = step_owned,
                        .created_at_ms = now,
                        .tenant_id = ctx.tenant_id,
                        .deadline_ms = deadline,
                    });
                    break;
                },
            }
        }

        return .{
            .run_id = run_id,
            .subject = try allocator.dupe(u8, subject),
            .amount = amount,
            .status = status,
            .entries = try entries.toOwnedSlice(allocator),
        };
    }

    fn enqueuePending(self: *ApprovalFlow, item: PendingItem) !void {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);
        try self.pending.append(self.allocator, item);
        if (self.db) |db| {
            const tenant_param: SqlParam = if (item.tenant_id) |t| .{ .int = t } else .null;
            const deadline_param: SqlParam = if (item.deadline_ms) |d| .{ .int = d } else .null;
            const params = [_]SqlParam{
                .{ .text = item.run_id },
                .{ .text = item.subject },
                .{ .int = item.amount },
                .{ .text = item.request },
                .{ .text = item.step_name },
                .{ .int = item.created_at_ms },
                tenant_param,
                deadline_param,
            };
            try db.execParams(
                "INSERT OR REPLACE INTO ai_approval_pending (run_id, subject, amount, request, step_name, status, created_at_ms, tenant_id, deadline_ms) VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?)",
                &params,
            );
        }
    }

    /// Copy pending items (caller frees strings). Prefers DB when attached.
    /// When `tenant_id` is set, only rows with that exact tenant are returned
    /// (null-tenant rows are excluded — stronger isolation).
    pub fn listPending(
        self: *ApprovalFlow,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(PendingItem),
        tenant_id: ?i64,
    ) !void {
        if (self.db) |db| {
            if (tenant_id) |tid| {
                const params = [_]SqlParam{.{ .int = tid }};
                var rs = try db.queryParams(
                    "SELECT run_id, subject, amount, request, step_name, created_at_ms, tenant_id, deadline_ms FROM ai_approval_pending WHERE status = 0 AND tenant_id = ? ORDER BY id ASC",
                    &params,
                );
                defer rs.deinit();
                try appendPendingRows(allocator, out, &rs);
            } else {
                var rs = try db.query(
                    "SELECT run_id, subject, amount, request, step_name, created_at_ms, tenant_id, deadline_ms FROM ai_approval_pending WHERE status = 0 ORDER BY id ASC",
                );
                defer rs.deinit();
                try appendPendingRows(allocator, out, &rs);
            }
            return;
        }
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);
        for (self.pending.items) |p| {
            if (tenant_id) |tid| {
                const pt = p.tenant_id orelse continue;
                if (pt != tid) continue;
            }
            try out.append(allocator, .{
                .run_id = try allocator.dupe(u8, p.run_id),
                .subject = try allocator.dupe(u8, p.subject),
                .amount = p.amount,
                .request = try allocator.dupe(u8, p.request),
                .step_name = try allocator.dupe(u8, p.step_name),
                .created_at_ms = p.created_at_ms,
                .tenant_id = p.tenant_id,
                .deadline_ms = p.deadline_ms,
            });
        }
    }

    /// Look up whether a run is still pending, approved, or rejected.
    pub fn lookup(self: *ApprovalFlow, run_id: []const u8) ResolveStatus {
        self.mutex.lock(self.io) catch return .unknown;
        defer self.mutex.unlock(self.io);
        for (self.pending.items) |p| {
            if (std.mem.eql(u8, p.run_id, run_id)) return .pending;
        }
        for (self.resolved.items) |r| {
            if (std.mem.eql(u8, r.run_id, run_id)) {
                return if (r.approved) .approved else .rejected;
            }
        }
        if (self.db) |db| {
            const params = [_]SqlParam{.{ .text = run_id }};
            var rs = db.queryParams(
                "SELECT status FROM ai_approval_pending WHERE run_id = ? LIMIT 1",
                &params,
            ) catch return .unknown;
            defer rs.deinit();
            if (rs.next()) {
                const row = rs.currentRowMut() orelse return .unknown;
                const st = (row.getInt(0) catch null) orelse return .unknown;
                return switch (st) {
                    0 => .pending,
                    1 => .approved,
                    2 => .rejected,
                    else => .unknown,
                };
            }
        }
        return .unknown;
    }

    /// Resolve pending `run_id`. When `tenant_id` is set, refuses cross-tenant resolve.
    pub fn resolve(self: *ApprovalFlow, run_id: []const u8, approve: bool) bool {
        return self.resolveForTenant(run_id, approve, null);
    }

    pub fn resolveForTenant(self: *ApprovalFlow, run_id: []const u8, approve: bool, tenant_id: ?i64) bool {
        var found_mem = false;
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);
        for (self.pending.items, 0..) |p, i| {
            if (std.mem.eql(u8, p.run_id, run_id)) {
                if (tenant_id) |tid| {
                    const pt = p.tenant_id orelse return false;
                    if (pt != tid) return false;
                }
                // Dupe into resolved BEFORE freePending — callers may pass p.run_id.
                self.rememberResolved(run_id, approve) catch {};
                freePending(self.allocator, p);
                _ = self.pending.orderedRemove(i);
                found_mem = true;
                break;
            }
        }
        var ok = found_mem;
        if (self.db) |db| {
            if (tenant_id) |tid| {
                const check = [_]SqlParam{ .{ .text = run_id }, .{ .int = tid } };
                var rs = db.queryParams(
                    "SELECT 1 FROM ai_approval_pending WHERE run_id = ? AND status = 0 AND tenant_id = ? LIMIT 1",
                    &check,
                ) catch {
                    if (found_mem) self.fireResolve(run_id, approve);
                    return found_mem;
                };
                defer rs.deinit();
                if (!rs.next()) {
                    if (!found_mem) return false;
                } else {
                    const status_code: i64 = if (approve) 1 else 2;
                    const upd = [_]SqlParam{ .{ .int = status_code }, .{ .text = run_id }, .{ .int = tid } };
                    db.execParams(
                        "UPDATE ai_approval_pending SET status = ? WHERE run_id = ? AND status = 0 AND tenant_id = ?",
                        &upd,
                    ) catch {
                        if (found_mem) self.fireResolve(run_id, approve);
                        return found_mem;
                    };
                    if (!found_mem) self.rememberResolved(run_id, approve) catch {};
                    ok = true;
                }
            } else {
                const params = [_]SqlParam{.{ .text = run_id }};
                var rs = db.queryParams(
                    "SELECT 1 FROM ai_approval_pending WHERE run_id = ? AND status = 0 LIMIT 1",
                    &params,
                ) catch {
                    if (found_mem) self.fireResolve(run_id, approve);
                    return found_mem;
                };
                defer rs.deinit();
                const in_db = rs.next();
                if (!in_db and !found_mem) return false;
                if (in_db) {
                    const status_code: i64 = if (approve) 1 else 2;
                    const upd = [_]SqlParam{ .{ .int = status_code }, .{ .text = run_id } };
                    db.execParams(
                        "UPDATE ai_approval_pending SET status = ? WHERE run_id = ? AND status = 0",
                        &upd,
                    ) catch {
                        if (found_mem) self.fireResolve(run_id, approve);
                        return found_mem;
                    };
                }
                if (!found_mem) self.rememberResolved(run_id, approve) catch {};
                ok = true;
            }
        }
        if (ok) self.fireResolve(run_id, approve);
        return ok;
    }

    fn fireResolve(self: *ApprovalFlow, run_id: []const u8, approve: bool) void {
        if (self.on_resolve) |cb| cb(self.on_resolve_ctx, run_id, approve);
    }

    fn rememberResolved(self: *ApprovalFlow, run_id: []const u8, approve: bool) !void {
        for (self.resolved.items) |*r| {
            if (std.mem.eql(u8, r.run_id, run_id)) {
                r.approved = approve;
                return;
            }
        }
        const id = try self.allocator.dupe(u8, run_id);
        errdefer self.allocator.free(id);
        try self.resolved.append(self.allocator, .{ .run_id = id, .approved = approve });
    }
};

fn appendPendingRows(allocator: std.mem.Allocator, out: *std.ArrayList(PendingItem), rs: anytype) !void {
    while (rs.next()) {
        const row = rs.currentRowMut() orelse continue;
        const tenant: ?i64 = row.getInt(6) catch null;
        const deadline: ?i64 = row.getInt(7) catch null;
        try out.append(allocator, .{
            .run_id = try allocator.dupe(u8, row.getText(0) orelse ""),
            .subject = try allocator.dupe(u8, row.getText(1) orelse ""),
            .amount = (row.getInt(2) catch null) orelse 0,
            .request = try allocator.dupe(u8, row.getText(3) orelse ""),
            .step_name = try allocator.dupe(u8, row.getText(4) orelse ""),
            .created_at_ms = (row.getInt(5) catch null) orelse 0,
            .tenant_id = tenant,
            .deadline_ms = deadline,
        });
    }
}

fn freePending(allocator: std.mem.Allocator, p: PendingItem) void {
    allocator.free(p.run_id);
    allocator.free(p.subject);
    allocator.free(p.request);
    allocator.free(p.step_name);
}

/// Safe default: escalate every step to a human.
pub fn defaultPolicy(
    _: std.mem.Allocator,
    _: *SkillContext,
    _: []const u8,
    _: i64,
    _: usize,
    _: []const u8,
    _: []const u8,
    _: *[]const u8,
) anyerror!ApprovalDecision {
    return .escalated;
}

pub const ApprovalCtx = struct {
    flow: *ApprovalFlow,
    steps: []const ApprovalStep,
};

fn putOwned(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    try obj.put(allocator, try allocator.dupe(u8, key), value);
}

pub fn registerApprovalSkills(registry: *SkillRegistry) !void {
    try registry.register(.{
        .name = "approval.submit",
        .description = "Submit a request through the app-registered approval chain; returns run_id and status",
        .parameters = &.{
            .{ .name = "subject", .type = .string, .description = "What is being approved", .required = true },
            .{ .name = "amount", .type = .number, .description = "Amount in minor units", .required = true },
            .{ .name = "request", .type = .string, .description = "Human-readable description", .required = true },
        },
        .handler = struct {
            fn h(sctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const ac: *ApprovalCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.ApprovalNotConfigured));
                if (args != .object) return error.InvalidArguments;
                const obj = args.object;
                const subj = obj.get("subject") orelse return error.InvalidArguments;
                const amt = obj.get("amount") orelse return error.InvalidArguments;
                const req = obj.get("request") orelse return error.InvalidArguments;
                if (subj != .string or amt != .integer or req != .string) return error.InvalidArguments;

                var result = try ac.flow.submit(sctx.allocator, sctx, subj.string, amt.integer, req.string, ac.steps);
                defer result.deinit(sctx.allocator);
                var out = std.json.ObjectMap{};
                try putOwned(&out, sctx.allocator, "run_id", .{ .string = try sctx.allocator.dupe(u8, result.run_id) });
                try putOwned(&out, sctx.allocator, "status", .{ .string = try sctx.allocator.dupe(u8, @tagName(result.status)) });
                return .{ .object = out };
            }
        }.h,
    });

    try registry.register(.{
        .name = "approval.list_pending",
        .description = "List human-pending approval runs",
        .parameters = &.{},
        .handler = struct {
            fn h(sctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const ac: *ApprovalCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.ApprovalNotConfigured));
                var items = std.ArrayList(PendingItem).empty;
                defer {
                    for (items.items) |p| {
                        sctx.allocator.free(p.run_id);
                        sctx.allocator.free(p.subject);
                        sctx.allocator.free(p.request);
                        sctx.allocator.free(p.step_name);
                    }
                    items.deinit(sctx.allocator);
                }
                try ac.flow.listPending(sctx.allocator, &items, sctx.tenant_id);
                var arr = std.json.Array.init(sctx.allocator);
                for (items.items) |p| {
                    var obj = std.json.ObjectMap{};
                    try putOwned(&obj, sctx.allocator, "run_id", .{ .string = try sctx.allocator.dupe(u8, p.run_id) });
                    try putOwned(&obj, sctx.allocator, "subject", .{ .string = try sctx.allocator.dupe(u8, p.subject) });
                    try putOwned(&obj, sctx.allocator, "amount", .{ .integer = p.amount });
                    try putOwned(&obj, sctx.allocator, "step", .{ .string = try sctx.allocator.dupe(u8, p.step_name) });
                    if (p.tenant_id) |tid| {
                        try putOwned(&obj, sctx.allocator, "tenant_id", .{ .integer = tid });
                    }
                    try arr.append(.{ .object = obj });
                }
                var out = std.json.ObjectMap{};
                try putOwned(&out, sctx.allocator, "pending", .{ .array = arr });
                return .{ .object = out };
            }
        }.h,
    });

    try registry.register(.{
        .name = "approval.resolve",
        .description = "Resolve a pending approval run (approve or reject)",
        .parameters = &.{
            .{ .name = "run_id", .type = .string, .description = "Pending run id", .required = true },
            .{ .name = "approve", .type = .boolean, .description = "true to approve, false to reject", .required = true },
        },
        .handler = struct {
            fn h(sctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const ac: *ApprovalCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.ApprovalNotConfigured));
                if (args != .object) return error.InvalidArguments;
                const obj = args.object;
                const id_v = obj.get("run_id") orelse return error.InvalidArguments;
                const ap_v = obj.get("approve") orelse return error.InvalidArguments;
                if (id_v != .string or ap_v != .bool) return error.InvalidArguments;
                const ok = ac.flow.resolveForTenant(id_v.string, ap_v.bool, sctx.tenant_id);
                var out = std.json.ObjectMap{};
                try putOwned(&out, sctx.allocator, "ok", .{ .bool = ok });
                return .{ .object = out };
            }
        }.h,
    });
}

/// Helper for `AgentHooks.on_tool_request`: deny tools that require human gate.
pub const ToolGate = struct {
    gated: []const []const u8 = &.{},
    deny_gated: bool = true,

    pub fn onRequest(self: *const ToolGate, name: []const u8) ToolApproval {
        for (self.gated) |g| {
            if (std.mem.eql(u8, g, name)) {
                return if (self.deny_gated) .deny else .allow;
            }
        }
        return .allow;
    }

    pub fn hook(ctx: ?*anyopaque, name: []const u8, _: []const u8) ToolApproval {
        const self: *const ToolGate = @ptrCast(@alignCast(ctx.?));
        return self.onRequest(name);
    }
};

test "approval flow escalates and lists pending" {
    const allocator = std.testing.allocator;
    var flow = ApprovalFlow.init(allocator, std.testing.io, defaultPolicy);
    defer flow.deinit();
    const steps = [_]ApprovalStep{.{ .name = "manager" }};
    var ctx = SkillContext{ .allocator = allocator };
    var result = try flow.submit(allocator, &ctx, "order-1", 100, "refund", &steps);
    defer result.deinit(allocator);
    try std.testing.expectEqual(ApprovalStatus.pending_human, result.status);

    var pending = std.ArrayList(PendingItem).empty;
    defer {
        for (pending.items) |p| {
            allocator.free(p.run_id);
            allocator.free(p.subject);
            allocator.free(p.request);
            allocator.free(p.step_name);
        }
        pending.deinit(allocator);
    }
    try flow.listPending(allocator, &pending, null);
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
    try std.testing.expect(flow.resolve(pending.items[0].run_id, true));
    try std.testing.expectEqual(ResolveStatus.approved, flow.lookup(pending.items[0].run_id));
    try std.testing.expectEqual(@as(usize, 0), flow.pending.items.len);
}

test "approval flow attachDb survives list after clear memory" {
    const allocator = std.testing.allocator;
    const DBConfig = @import("../db/config.zig").DBConfig;
    var db = try DB.init(allocator, DBConfig.sqliteMemory());
    defer db.destroy();

    var flow = ApprovalFlow.init(allocator, std.testing.io, defaultPolicy);
    defer flow.deinit();
    try flow.attachDb(db);
    const steps = [_]ApprovalStep{.{ .name = "manager" }};
    var ctx = SkillContext{ .allocator = allocator };
    var result = try flow.submit(allocator, &ctx, "order-db", 50, "req", &steps);
    defer result.deinit(allocator);

    for (flow.pending.items) |p| freePending(flow.allocator, p);
    flow.pending.clearRetainingCapacity();

    var pending = std.ArrayList(PendingItem).empty;
    defer {
        for (pending.items) |p| {
            allocator.free(p.run_id);
            allocator.free(p.subject);
            allocator.free(p.request);
            allocator.free(p.step_name);
        }
        pending.deinit(allocator);
    }
    try flow.listPending(allocator, &pending, null);
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
    try std.testing.expect(flow.resolve(pending.items[0].run_id, true));
}

test "approval listPending filters by tenant_id" {
    const allocator = std.testing.allocator;
    var flow = ApprovalFlow.init(allocator, std.testing.io, defaultPolicy);
    defer flow.deinit();
    const steps = [_]ApprovalStep{.{ .name = "manager" }};
    var ctx7 = SkillContext{ .allocator = allocator, .tenant_id = 7 };
    var ctx9 = SkillContext{ .allocator = allocator, .tenant_id = 9 };
    var r7 = try flow.submit(allocator, &ctx7, "a", 1, "r", &steps);
    defer r7.deinit(allocator);
    var r9 = try flow.submit(allocator, &ctx9, "b", 2, "r", &steps);
    defer r9.deinit(allocator);

    var only7 = std.ArrayList(PendingItem).empty;
    defer {
        for (only7.items) |p| {
            allocator.free(p.run_id);
            allocator.free(p.subject);
            allocator.free(p.request);
            allocator.free(p.step_name);
        }
        only7.deinit(allocator);
    }
    try flow.listPending(allocator, &only7, 7);
    try std.testing.expectEqual(@as(usize, 1), only7.items.len);
    try std.testing.expectEqual(@as(i64, 7), only7.items[0].tenant_id.?);
}

test "approval resolve reject is visible via lookup" {
    const allocator = std.testing.allocator;
    var flow = ApprovalFlow.init(allocator, std.testing.io, defaultPolicy);
    defer flow.deinit();
    const steps = [_]ApprovalStep{.{ .name = "manager" }};
    var ctx = SkillContext{ .allocator = allocator };
    var result = try flow.submit(allocator, &ctx, "x", 1, "r", &steps);
    defer result.deinit(allocator);
    try std.testing.expect(flow.resolve(result.run_id, false));
    try std.testing.expectEqual(ResolveStatus.rejected, flow.lookup(result.run_id));
}

test "approval resolveForTenant rejects cross-tenant" {
    const allocator = std.testing.allocator;
    var flow = ApprovalFlow.init(allocator, std.testing.io, defaultPolicy);
    defer flow.deinit();
    const steps = [_]ApprovalStep{.{ .name = "manager" }};
    var ctx7 = SkillContext{ .allocator = allocator, .tenant_id = 7 };
    var result = try flow.submit(allocator, &ctx7, "x", 1, "r", &steps);
    defer result.deinit(allocator);
    try std.testing.expect(!flow.resolveForTenant(result.run_id, true, 9));
    try std.testing.expectEqual(ResolveStatus.pending, flow.lookup(result.run_id));
    try std.testing.expect(flow.resolveForTenant(result.run_id, true, 7));
}

test "approval on_resolve hook fires" {
    const allocator = std.testing.allocator;
    var seen: usize = 0;
    const Hook = struct {
        fn h(ctx: ?*anyopaque, _: []const u8, approved: bool) void {
            const c: *usize = @ptrCast(@alignCast(ctx.?));
            if (approved) c.* += 1;
        }
    };
    var flow = ApprovalFlow.init(allocator, std.testing.io, defaultPolicy);
    defer flow.deinit();
    flow.on_resolve = Hook.h;
    flow.on_resolve_ctx = @ptrCast(&seen);
    const steps = [_]ApprovalStep{.{ .name = "manager" }};
    var ctx = SkillContext{ .allocator = allocator };
    var result = try flow.submit(allocator, &ctx, "hook", 1, "r", &steps);
    defer result.deinit(allocator);
    try std.testing.expect(flow.resolve(result.run_id, true));
    try std.testing.expectEqual(@as(usize, 1), seen);
}

test "ToolGate denies gated tools" {
    const gate = ToolGate{ .gated = &.{"db.query"} };
    try std.testing.expectEqual(ToolApproval.deny, gate.onRequest("db.query"));
    try std.testing.expectEqual(ToolApproval.allow, gate.onRequest("ping"));
}
