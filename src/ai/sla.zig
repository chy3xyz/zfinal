//! Lightweight SLA checks for pending approvals (warn / breach).
//!
//! Call `checkApprovalSla` on a cron / Trigger tick. No outbox dependency —
//! wire `on_hit` to notify / metrics yourself.

const std = @import("std");
const ApprovalFlow = @import("approval.zig").ApprovalFlow;
const PendingItem = @import("approval.zig").PendingItem;
const time_util = @import("time_util.zig");

pub const SlaLevel = enum { warn, breach };

pub const SlaHit = struct {
    run_id: []const u8,
    subject: []const u8,
    step_name: []const u8,
    level: SlaLevel,
    remaining_ms: i64,
    deadline_ms: i64,
    tenant_id: ?i64 = null,

    pub fn deinit(self: SlaHit, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        allocator.free(self.subject);
        allocator.free(self.step_name);
    }
};

pub const SlaHitFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    hit: SlaHit,
) anyerror!void;

/// Scan pending approvals with a deadline. Appends owned `SlaHit`s to `out`
/// (caller frees via `SlaHit.deinit`). Returns number of hits.
pub fn checkApprovalSla(
    flow: *ApprovalFlow,
    allocator: std.mem.Allocator,
    warn_before_ms: i64,
    out: *std.ArrayList(SlaHit),
) !usize {
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

    const now = time_util.nowMillis();
    var fired: usize = 0;
    for (pending.items) |p| {
        const deadline = p.deadline_ms orelse continue;
        const remaining = deadline - now;
        const level: SlaLevel = if (remaining < 0)
            .breach
        else if (remaining <= warn_before_ms)
            .warn
        else
            continue;
        try out.append(allocator, .{
            .run_id = try allocator.dupe(u8, p.run_id),
            .subject = try allocator.dupe(u8, p.subject),
            .step_name = try allocator.dupe(u8, p.step_name),
            .level = level,
            .remaining_ms = remaining,
            .deadline_ms = deadline,
            .tenant_id = p.tenant_id,
        });
        fired += 1;
    }
    return fired;
}

/// Same as `checkApprovalSla` but invokes `on_hit` for each violation.
pub fn checkApprovalSlaWithHook(
    flow: *ApprovalFlow,
    allocator: std.mem.Allocator,
    warn_before_ms: i64,
    hook_ctx: ?*anyopaque,
    on_hit: ?SlaHitFn,
) !usize {
    var hits = std.ArrayList(SlaHit).empty;
    defer {
        for (hits.items) |h| h.deinit(allocator);
        hits.deinit(allocator);
    }
    const n = try checkApprovalSla(flow, allocator, warn_before_ms, &hits);
    if (on_hit) |cb| {
        for (hits.items) |h| try cb(hook_ctx, allocator, h);
    }
    return n;
}

test "checkApprovalSla warns and breaches by deadline" {
    const allocator = std.testing.allocator;
    const defaultPolicy = @import("approval.zig").defaultPolicy;
    const ApprovalStep = @import("approval.zig").ApprovalStep;
    const SkillContext = @import("skill.zig").SkillContext;

    var flow = ApprovalFlow.init(allocator, std.testing.io, defaultPolicy);
    defer flow.deinit();
    flow.default_sla_ms = 1; // essentially immediate
    const steps = [_]ApprovalStep{.{ .name = "mgr" }};
    var ctx = SkillContext{ .allocator = allocator };
    var result = try flow.submit(allocator, &ctx, "late-order", 10, "req", &steps);
    defer result.deinit(allocator);

    // Force deadline into the past.
    if (flow.pending.items.len > 0) {
        flow.pending.items[0].deadline_ms = time_util.nowMillis() - 5_000;
    }

    var hits = std.ArrayList(SlaHit).empty;
    defer {
        for (hits.items) |h| h.deinit(allocator);
        hits.deinit(allocator);
    }
    const n = try checkApprovalSla(&flow, allocator, 60_000, &hits);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(SlaLevel.breach, hits.items[0].level);
}

/// Dedup SLA notifications: only fire hook when level is new or escalated for a run_id.
pub const SlaNotifyGate = struct {
    allocator: std.mem.Allocator,
    /// run_id → highest level notified (warn=1, breach=2)
    seen: std.StringHashMap(u8),

    pub fn init(allocator: std.mem.Allocator) SlaNotifyGate {
        return .{ .allocator = allocator, .seen = std.StringHashMap(u8).init(allocator) };
    }

    pub fn deinit(self: *SlaNotifyGate) void {
        var it = self.seen.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.seen.deinit();
    }

    fn levelRank(level: SlaLevel) u8 {
        return switch (level) {
            .warn => 1,
            .breach => 2,
        };
    }

    /// Returns true if this hit should notify (first time or escalation).
    pub fn shouldNotify(self: *SlaNotifyGate, hit: SlaHit) !bool {
        const rank = levelRank(hit.level);
        const gop = try self.seen.getOrPut(hit.run_id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, hit.run_id);
            gop.value_ptr.* = rank;
            return true;
        }
        if (rank > gop.value_ptr.*) {
            gop.value_ptr.* = rank;
            return true;
        }
        return false;
    }
};

/// Like `checkApprovalSlaWithHook` but skips already-notified levels via `gate`.
pub fn checkApprovalSlaDedup(
    flow: *ApprovalFlow,
    allocator: std.mem.Allocator,
    warn_before_ms: i64,
    gate: *SlaNotifyGate,
    hook_ctx: ?*anyopaque,
    on_hit: ?SlaHitFn,
) !usize {
    var hits = std.ArrayList(SlaHit).empty;
    defer {
        for (hits.items) |h| h.deinit(allocator);
        hits.deinit(allocator);
    }
    _ = try checkApprovalSla(flow, allocator, warn_before_ms, &hits);
    var fired: usize = 0;
    for (hits.items) |h| {
        if (!try gate.shouldNotify(h)) continue;
        fired += 1;
        if (on_hit) |cb| try cb(hook_ctx, allocator, h);
    }
    return fired;
}

test "SlaNotifyGate dedups same level" {
    const a = std.testing.allocator;
    var gate = SlaNotifyGate.init(a);
    defer gate.deinit();
    const hit = SlaHit{
        .run_id = "r1",
        .subject = "s",
        .step_name = "st",
        .level = .warn,
        .remaining_ms = 1,
        .deadline_ms = 2,
    };
    try std.testing.expect(try gate.shouldNotify(hit));
    try std.testing.expect(!(try gate.shouldNotify(hit)));
    var breach = hit;
    breach.level = .breach;
    try std.testing.expect(try gate.shouldNotify(breach));
}
