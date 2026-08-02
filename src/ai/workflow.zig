//! Linear / DAG multi-step agent workflow (orchestration).
//!
//! Runs `llm` / `skill` / `agent` / `approval` steps with optional `depends_on`.
//! DAG waves run sequentially by default; set `io` + `max_parallel > 1` for
//! parallel waves via `std.Io.Group`. Optional JSON checkpoint resume
//! (`dumpCheckpoint` / `runFromCheckpoint` / `saveCheckpoint` / `loadCheckpointFile`).
//! `.approval` steps need `approval_flow`; escalation stops the run as
//! `.pending_human` (resume after a human resolves via ApprovalFlow / HTTP).

const std = @import("std");
const provider_mod = @import("provider.zig");
const skill_mod = @import("skill.zig");
const agent_mod = @import("agent.zig");
const approval_mod = @import("approval.zig");
const journal_mod = @import("workflow_journal.zig");
const tokenizer = @import("tokenizer.zig");
const Budget = @import("budget.zig").Budget;
const RunAuditStore = @import("run_audit.zig").RunAuditStore;
const time_util = @import("time_util.zig");

pub const AiProvider = provider_mod.AiProvider;
pub const SkillRegistry = skill_mod.SkillRegistry;
pub const SkillContext = skill_mod.SkillContext;
pub const Agent = agent_mod.Agent;
pub const WorkflowJournal = journal_mod.WorkflowJournal;
pub const JournalLine = journal_mod.JournalLine;

pub const StepKind = union(enum) {
    llm: struct { prompt: []const u8 },
    skill: struct { name: []const u8, args: std.json.Value },
    agent: struct { goal: []const u8, max_steps: usize },
    /// Human-in-the-loop gate; stops with `.pending_human` on escalate.
    approval: struct { subject: []const u8, amount: i64, request: []const u8 = "" },
};

pub const Step = struct {
    name: []const u8,
    kind: StepKind,
    retry: usize = 0,
    /// DAG dependency: run only after these step names complete. Empty keeps
    /// linear (declaration order) semantics.
    depends_on: []const []const u8 = &.{},
};

pub const StepStatus = enum { pending, running, completed, failed, pending_human };
pub const RunStatus = enum { completed, failed, budget_exhausted, pending_human };
pub const EscalateReason = enum { step_failed, budget_exhausted, verification_failed };

pub const VerifyFn = *const fn (
    ctx: *SkillContext,
    goal: []const u8,
    output: []const u8,
    allocator: std.mem.Allocator,
) anyerror!bool;

pub const EscalateFn = *const fn (
    ctx: *SkillContext,
    reason: EscalateReason,
    step: ?[]const u8,
    allocator: std.mem.Allocator,
) anyerror!void;

pub const StepRecord = struct {
    name: []const u8,
    status: StepStatus,
    error_message: ?[]const u8 = null,
    output: []const u8 = "",
};

pub const WorkflowResult = struct {
    status: RunStatus,
    steps: std.ArrayList(StepRecord),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WorkflowResult) void {
        for (self.steps.items) |rec| {
            self.allocator.free(rec.name);
            if (rec.error_message) |em| self.allocator.free(em);
            if (rec.output.len > 0) self.allocator.free(rec.output);
        }
        self.steps.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const WorkflowMetrics = struct {
    runs: usize = 0,
    completed_steps: usize = 0,
    failed_steps: usize = 0,
    escalations: usize = 0,
    reviews: usize = 0,
    pending_human_stops: usize = 0,
    gate_rejects: usize = 0,
    journal_resumes: usize = 0,

    pub fn toPrometheusFormat(self: WorkflowMetrics, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.print(allocator, "# HELP zfinal_ai_workflow_runs_total Workflow runs started.\n", .{});
        try buf.print(allocator, "# TYPE zfinal_ai_workflow_runs_total counter\n", .{});
        try buf.print(allocator, "zfinal_ai_workflow_runs_total{{workflow=\"{s}\"}} {d}\n", .{ name, self.runs });
        try buf.print(allocator, "# TYPE zfinal_ai_workflow_steps_total counter\n", .{});
        try buf.print(allocator, "zfinal_ai_workflow_steps_total{{workflow=\"{s}\",status=\"completed\"}} {d}\n", .{ name, self.completed_steps });
        try buf.print(allocator, "zfinal_ai_workflow_steps_total{{workflow=\"{s}\",status=\"failed\"}} {d}\n", .{ name, self.failed_steps });
        try buf.print(allocator, "# TYPE zfinal_ai_workflow_escalations_total counter\n", .{});
        try buf.print(allocator, "zfinal_ai_workflow_escalations_total{{workflow=\"{s}\"}} {d}\n", .{ name, self.escalations });
        try buf.print(allocator, "# TYPE zfinal_ai_workflow_reviews_total counter\n", .{});
        try buf.print(allocator, "zfinal_ai_workflow_reviews_total{{workflow=\"{s}\"}} {d}\n", .{ name, self.reviews });
        try buf.print(allocator, "# TYPE zfinal_ai_workflow_pending_human_total counter\n", .{});
        try buf.print(allocator, "zfinal_ai_workflow_pending_human_total{{workflow=\"{s}\"}} {d}\n", .{ name, self.pending_human_stops });
        try buf.print(allocator, "# TYPE zfinal_ai_workflow_gate_rejects_total counter\n", .{});
        try buf.print(allocator, "zfinal_ai_workflow_gate_rejects_total{{workflow=\"{s}\"}} {d}\n", .{ name, self.gate_rejects });
        try buf.print(allocator, "# TYPE zfinal_ai_workflow_journal_resumes_total counter\n", .{});
        try buf.print(allocator, "zfinal_ai_workflow_journal_resumes_total{{workflow=\"{s}\"}} {d}\n", .{ name, self.journal_resumes });
        return try buf.toOwnedSlice(allocator);
    }
};

const StepOutcome = struct {
    output: []const u8,
    budget_exhausted: bool = false,
    pending_human: bool = false,
};

pub const Workflow = struct {
    provider: ?*AiProvider = null,
    registry: *SkillRegistry,
    budget: ?*Budget = null,
    steps: []const Step,
    reflection: ?VerifyFn = null,
    max_reviews: usize = 1,
    on_escalate: ?EscalateFn = null,
    goal: []const u8 = "",
    metrics: ?*WorkflowMetrics = null,
    /// Required for parallel DAG waves (`max_parallel > 1`).
    io: ?std.Io = null,
    /// Max concurrent steps in a ready DAG wave. `1` = sequential (default).
    max_parallel: usize = 1,
    /// Optional durable run trail (one row per workflow.run).
    run_audit: ?*RunAuditStore = null,
    /// Optional tool audit (passed through to embedded Agent steps).
    audit: ?*@import("audit.zig").AgentAuditLog = null,
    /// Optional tool allowlist for embedded Agent steps.
    allowlist: ?[]const []const u8 = null,
    /// Required when any step uses `.approval`.
    approval_flow: ?*approval_mod.ApprovalFlow = null,
    /// Optional JSONL step journal (lightweight WAL).
    journal: ?*WorkflowJournal = null,
    /// Namespace for journal entries; required when `journal` is set.
    run_id: []const u8 = "",

    pub fn init(registry: *SkillRegistry, steps: []const Step) Workflow {
        return .{ .registry = registry, .steps = steps };
    }

    /// Mermaid `flowchart TD`. Caller frees.
    pub fn toMermaid(self: Workflow, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, "flowchart TD\n");
        for (self.steps) |step| {
            const kind = switch (step.kind) {
                .llm => "llm",
                .skill => "skill",
                .agent => "agent",
                .approval => "approval",
            };
            try buf.print(allocator, "  {s}[\"{s} ({s})\"]\n", .{ step.name, step.name, kind });
        }
        if (self.hasDeps()) {
            for (self.steps) |step| {
                for (step.depends_on) |dep| {
                    try buf.print(allocator, "  {s} --> {s}\n", .{ dep, step.name });
                }
            }
        } else {
            var prev: ?[]const u8 = null;
            for (self.steps) |step| {
                if (prev) |p| try buf.print(allocator, "  {s} --> {s}\n", .{ p, step.name });
                prev = step.name;
            }
        }
        return buf.toOwnedSlice(allocator);
    }

    /// Snapshot a run trail as JSON. Caller frees.
    pub fn dumpCheckpoint(result: *const WorkflowResult, allocator: std.mem.Allocator) ![]u8 {
        const Rec = struct {
            name: []const u8,
            status: []const u8,
            error_message: ?[]const u8 = null,
            output: []const u8 = "",
        };
        var rows = std.ArrayList(Rec).empty;
        defer rows.deinit(allocator);
        for (result.steps.items) |r| {
            try rows.append(allocator, .{
                .name = r.name,
                .status = @tagName(r.status),
                .error_message = r.error_message,
                .output = r.output,
            });
        }
        const Doc = struct {
            status: []const u8,
            steps: []const Rec,
        };
        return try std.json.Stringify.valueAlloc(allocator, Doc{
            .status = @tagName(result.status),
            .steps = rows.items,
        }, .{});
    }

    pub fn saveCheckpoint(result: *const WorkflowResult, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        const json = try dumpCheckpoint(result, allocator);
        defer allocator.free(json);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try std.Io.File.writeStreamingAll(file, io, json);
    }

    /// Load checkpoint JSON into a partial `WorkflowResult` (caller owns).
    pub fn loadCheckpoint(allocator: std.mem.Allocator, json: []const u8) !WorkflowResult {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidCheckpoint;
        var result = WorkflowResult{
            .status = .completed,
            .steps = std.ArrayList(StepRecord).empty,
            .allocator = allocator,
        };
        errdefer result.deinit();

        if (parsed.value.object.get("status")) |sv| {
            if (sv == .string) {
                if (std.mem.eql(u8, sv.string, "failed")) result.status = .failed;
                if (std.mem.eql(u8, sv.string, "budget_exhausted")) result.status = .budget_exhausted;
                if (std.mem.eql(u8, sv.string, "pending_human")) result.status = .pending_human;
            }
        }
        const steps_v = parsed.value.object.get("steps") orelse return error.InvalidCheckpoint;
        if (steps_v != .array) return error.InvalidCheckpoint;
        for (steps_v.array.items) |item| {
            if (item != .object) continue;
            const name = switch (item.object.get("name") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const st_s: []const u8 = blk: {
                const sv = item.object.get("status") orelse break :blk "completed";
                break :blk switch (sv) {
                    .string => |s| s,
                    else => "completed",
                };
            };
            const status: StepStatus = if (std.mem.eql(u8, st_s, "failed"))
                .failed
            else if (std.mem.eql(u8, st_s, "running"))
                .running
            else if (std.mem.eql(u8, st_s, "pending"))
                .pending
            else if (std.mem.eql(u8, st_s, "pending_human"))
                .pending_human
            else
                .completed;
            const output: []const u8 = blk: {
                const ov = item.object.get("output") orelse break :blk "";
                break :blk switch (ov) {
                    .string => |s| s,
                    else => "",
                };
            };
            const err_msg: ?[]const u8 = blk: {
                const ev = item.object.get("error_message") orelse break :blk null;
                break :blk switch (ev) {
                    .string => |s| s,
                    .null => null,
                    else => null,
                };
            };
            try result.steps.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .status = status,
                .error_message = if (err_msg) |e| try allocator.dupe(u8, e) else null,
                .output = try allocator.dupe(u8, output),
            });
        }
        return result;
    }

    pub fn loadCheckpointFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !WorkflowResult {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        const json = try allocator.alloc(u8, @as(usize, @intCast(stat.size)));
        defer allocator.free(json);
        const n = try std.Io.File.readPositionalAll(file, io, json, 0);
        return loadCheckpoint(allocator, json[0..n]);
    }

    pub fn run(self: Workflow, allocator: std.mem.Allocator, ctx: *SkillContext) !WorkflowResult {
        const started = time_util.nowMillis();
        var result = WorkflowResult{
            .status = .completed,
            .steps = std.ArrayList(StepRecord).empty,
            .allocator = allocator,
        };
        errdefer result.deinit();
        var completed = std.StringHashMap(void).init(allocator);
        defer completed.deinit();
        if (self.metrics) |m| m.runs += 1;
        try self.runSteps(allocator, ctx, &completed, &result);
        if (self.run_audit) |store| {
            store.record(.{
                .run_id = ctx.run_id orelse "workflow",
                .kind = .workflow,
                .status = @tagName(result.status),
                .tenant_id = ctx.tenant_id,
                .steps = result.steps.items.len,
                .duration_ms = time_util.nowMillis() - started,
            });
        }
        return result;
    }

    /// Resume after a checkpoint: replays completed steps into the result, then
    /// continues remaining steps. Failed checkpoints return as-is.
    ///
    /// For `.pending_human` steps: when `approval_flow` is set, consults
    /// `lookup(run_id)` — still pending / unknown → return without advancing;
    /// rejected → `.failed`; approved → treat gate as done and continue.
    pub fn runFromCheckpoint(
        self: Workflow,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        checkpoint_json: []const u8,
    ) !WorkflowResult {
        var result = try loadCheckpoint(allocator, checkpoint_json);
        errdefer result.deinit();
        try self.resumePartial(allocator, ctx, &result);
        return result;
    }

    /// Resume from JSONL journal (`journal` + matching `run_id` file).
    pub fn resumeFromJournal(
        self: Workflow,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        run_id: []const u8,
    ) !WorkflowResult {
        const j = self.journal orelse return error.JournalRequired;
        var lines = std.ArrayList(JournalLine).empty;
        defer {
            WorkflowJournal.freeLines(allocator, lines.items);
            lines.deinit(allocator);
        }
        try j.loadLines(allocator, run_id, &lines);

        var result = WorkflowResult{
            .status = .completed,
            .steps = std.ArrayList(StepRecord).empty,
            .allocator = allocator,
        };
        errdefer result.deinit();

        for (lines.items) |line| {
            const status: StepStatus = if (std.mem.eql(u8, line.status, "failed"))
                .failed
            else if (std.mem.eql(u8, line.status, "pending_human"))
                .pending_human
            else
                .completed;
            try result.steps.append(allocator, .{
                .name = try allocator.dupe(u8, line.name),
                .status = status,
                .error_message = if (line.error_message) |e| try allocator.dupe(u8, e) else null,
                .output = try allocator.dupe(u8, line.output),
            });
            if (status == .failed) result.status = .failed;
            if (status == .pending_human and result.status != .failed) result.status = .pending_human;
        }
        try self.resumePartial(allocator, ctx, &result);
        if (self.metrics) |m| m.journal_resumes += 1;
        return result;
    }

    fn resumePartial(
        self: Workflow,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        result: *WorkflowResult,
    ) !void {
        if (result.status == .failed or result.status == .budget_exhausted) return;

        var completed = std.StringHashMap(void).init(allocator);
        defer completed.deinit();
        if (try self.applyPendingGates(allocator, result, &completed)) return;

        if (self.metrics) |m| m.runs += 1;
        result.status = .completed;
        try self.runSteps(allocator, ctx, &completed, result);
    }

    /// Returns true when resume should stop (pending / rejected gate).
    fn applyPendingGates(
        self: Workflow,
        allocator: std.mem.Allocator,
        result: *WorkflowResult,
        completed: *std.StringHashMap(void),
    ) !bool {
        for (result.steps.items) |*rec| {
            if (rec.status == .completed) {
                try completed.put(rec.name, {});
                continue;
            }
            if (rec.status != .pending_human) continue;

            const gate = try self.gateDecision(allocator, rec.output);
            switch (gate) {
                .approved => try completed.put(rec.name, {}),
                .pending, .unknown => {
                    result.status = .pending_human;
                    if (self.metrics) |m| m.pending_human_stops += 1;
                    return true;
                },
                .rejected => {
                    if (rec.error_message) |em| allocator.free(em);
                    rec.status = .failed;
                    rec.error_message = try allocator.dupe(u8, "approval_rejected");
                    result.status = .failed;
                    if (self.metrics) |m| m.gate_rejects += 1;
                    return true;
                },
            }
        }
        return false;
    }

    fn gateDecision(self: Workflow, allocator: std.mem.Allocator, output: []const u8) !approval_mod.ResolveStatus {
        const flow = self.approval_flow orelse return .approved;
        if (output.len == 0 or std.mem.eql(u8, output, "pending_human")) return .pending;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, output, .{}) catch return .pending;
        defer parsed.deinit();
        if (parsed.value != .object) return .pending;
        const id_v = parsed.value.object.get("run_id") orelse return .pending;
        const run_id = switch (id_v) {
            .string => |s| s,
            else => return .pending,
        };
        return flow.lookup(run_id);
    }

    fn hasDeps(self: Workflow) bool {
        for (self.steps) |s| {
            if (s.depends_on.len > 0) return true;
        }
        return false;
    }

    fn runSteps(
        self: Workflow,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        completed: *std.StringHashMap(void),
        result: *WorkflowResult,
    ) !void {
        if (self.hasDeps()) {
            return self.runDag(allocator, ctx, completed, result);
        }
        return self.runLinear(allocator, ctx, completed, result);
    }

    fn runLinear(
        self: Workflow,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        completed: *std.StringHashMap(void),
        result: *WorkflowResult,
    ) !void {
        for (self.steps, 0..) |step, step_index| {
            if (completed.contains(step.name)) continue;
            var outcome = try self.executeStep(allocator, ctx, step, result);
            if (outcome == null) {
                try self.maybeEscalate(ctx, .step_failed, step.name, allocator);
                result.status = .failed;
                break;
            }
            try completed.put(step.name, {});
            if (outcome.?.budget_exhausted) {
                try self.maybeEscalate(ctx, .budget_exhausted, step.name, allocator);
                result.status = .budget_exhausted;
                break;
            }
            if (outcome.?.pending_human) {
                result.status = .pending_human;
                if (self.metrics) |m| m.pending_human_stops += 1;
                break;
            }
            if (step_index == self.steps.len - 1) {
                if (!try self.runReflection(allocator, ctx, step, step_index, &outcome, result)) break;
            }
        }
    }

    /// Topological waves; parallel when `io != null` and `max_parallel > 1`.
    fn runDag(
        self: Workflow,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        completed: *std.StringHashMap(void),
        result: *WorkflowResult,
    ) !void {
        var remaining: usize = self.steps.len;
        for (self.steps) |s| {
            if (completed.contains(s.name)) remaining -= 1;
        }

        const parallel = self.max_parallel > 1 and self.io != null;

        while (remaining > 0) {
            var ready = std.ArrayList(usize).empty;
            defer ready.deinit(allocator);
            for (self.steps, 0..) |s, i| {
                if (completed.contains(s.name)) continue;
                var deps_ok = true;
                for (s.depends_on) |d| {
                    if (!completed.contains(d)) {
                        deps_ok = false;
                        break;
                    }
                }
                if (deps_ok) try ready.append(allocator, i);
            }
            if (ready.items.len == 0) return error.CyclicDependency;

            if (!parallel) {
                for (ready.items) |idx| {
                    const step = self.steps[idx];
                    const outcome = try self.executeStep(allocator, ctx, step, result);
                    if (outcome == null) {
                        try self.maybeEscalate(ctx, .step_failed, step.name, allocator);
                        result.status = .failed;
                        return;
                    }
                    try completed.put(step.name, {});
                    remaining -= 1;
                    if (outcome.?.budget_exhausted) {
                        try self.maybeEscalate(ctx, .budget_exhausted, step.name, allocator);
                        result.status = .budget_exhausted;
                        return;
                    }
                    if (outcome.?.pending_human) {
                        result.status = .pending_human;
                        if (self.metrics) |m| m.pending_human_stops += 1;
                        return;
                    }
                }
            } else {
                const io = self.io.?;
                var wave: usize = 0;
                while (wave < ready.items.len) : (wave += self.max_parallel) {
                    const end = @min(ready.items.len, wave + self.max_parallel);
                    const count = end - wave;
                    const states = try allocator.alloc(*DagState, count);
                    defer allocator.free(states);
                    var group = std.Io.Group.init;
                    for (ready.items[wave..end], 0..) |idx, k| {
                        const st = try allocator.create(DagState);
                        st.* = .{
                            .wf = self,
                            .allocator = allocator,
                            .ctx = ctx.*,
                            .step = self.steps[idx],
                            .index = idx,
                        };
                        states[k] = st;
                        group.async(io, dagTask, .{st});
                    }
                    try group.await(io);

                    for (states) |st| {
                        if (st.outcome) |o| {
                            try self.appendCompleted(result, allocator, st.step, o);
                            try completed.put(st.step.name, {});
                            remaining -= 1;
                            if (o.budget_exhausted) {
                                try self.maybeEscalate(ctx, .budget_exhausted, st.step.name, allocator);
                                result.status = .budget_exhausted;
                            } else if (o.pending_human) {
                                result.status = .pending_human;
                                if (self.metrics) |m| m.pending_human_stops += 1;
                            }
                        } else {
                            try self.appendFailed(result, allocator, st.step, st.last_err);
                            try self.maybeEscalate(ctx, .step_failed, st.step.name, allocator);
                            result.status = .failed;
                        }
                    }
                    for (states) |st| allocator.destroy(st);
                    if (result.status != .completed) return;
                }
            }
            if (result.status != .completed) return;
        }
    }

    const DagState = struct {
        wf: Workflow,
        allocator: std.mem.Allocator,
        ctx: SkillContext,
        step: Step,
        index: usize,
        outcome: ?StepOutcome = null,
        last_err: anyerror = error.Unknown,
    };

    fn dagTask(st: *DagState) void {
        st.outcome = st.wf.attemptStep(st.allocator, &st.ctx, st.step) catch |err| blk: {
            st.last_err = err;
            break :blk null;
        };
    }

    fn runReflection(
        self: Workflow,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        step: Step,
        step_index: usize,
        outcome: *?StepOutcome,
        result: *WorkflowResult,
    ) !bool {
        _ = step_index;
        const vf = self.reflection orelse return true;
        var reviews: usize = 0;
        var verified = try vf(ctx, self.goal, outcome.*.?.output, allocator);
        while (!verified) : (reviews += 1) {
            if (self.metrics) |m| m.reviews += 1;
            if (reviews >= self.max_reviews) {
                try self.maybeEscalate(ctx, .verification_failed, step.name, allocator);
                result.status = .failed;
                return false;
            }
            outcome.* = try self.executeStep(allocator, ctx, step, result);
            if (outcome.* == null) {
                try self.maybeEscalate(ctx, .step_failed, step.name, allocator);
                result.status = .failed;
                return false;
            }
            verified = try vf(ctx, self.goal, outcome.*.?.output, allocator);
        }
        return true;
    }

    fn executeStep(
        self: Workflow,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        step: Step,
        result: *WorkflowResult,
    ) !?StepOutcome {
        const outcome = self.attemptStep(allocator, ctx, step) catch |err| {
            try self.appendFailed(result, allocator, step, err);
            return null;
        };
        try self.appendCompleted(result, allocator, step, outcome);
        return outcome;
    }

    fn attemptStep(
        self: Workflow,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        step: Step,
    ) !StepOutcome {
        var attempts: usize = 0;
        var last_err: anyerror = error.Unknown;
        while (attempts <= step.retry) : (attempts += 1) {
            const outcome = self.runStep(allocator, ctx, step) catch |err| {
                last_err = err;
                continue;
            };
            return outcome;
        }
        return last_err;
    }

    fn appendCompleted(
        self: Workflow,
        result: *WorkflowResult,
        allocator: std.mem.Allocator,
        step: Step,
        outcome: StepOutcome,
    ) !void {
        if (self.metrics) |m| m.completed_steps += 1;
        const rec = StepRecord{
            .name = try allocator.dupe(u8, step.name),
            .status = if (outcome.pending_human) .pending_human else .completed,
            .output = outcome.output,
        };
        try result.steps.append(allocator, rec);
        try self.persistJournal(rec);
    }

    fn appendFailed(
        self: Workflow,
        result: *WorkflowResult,
        allocator: std.mem.Allocator,
        step: Step,
        last_err: anyerror,
    ) !void {
        if (self.metrics) |m| m.failed_steps += 1;
        const rec = StepRecord{
            .name = try allocator.dupe(u8, step.name),
            .status = .failed,
            .error_message = if (last_err != error.Unknown)
                try allocator.dupe(u8, @errorName(last_err))
            else
                null,
        };
        try result.steps.append(allocator, rec);
        try self.persistJournal(rec);
    }

    fn persistJournal(self: Workflow, rec: StepRecord) !void {
        const j = self.journal orelse return;
        if (self.run_id.len == 0) return;
        try j.append(self.run_id, .{
            .name = rec.name,
            .status = @tagName(rec.status),
            .error_message = rec.error_message,
            .output = rec.output,
        });
    }

    fn maybeEscalate(
        self: Workflow,
        ctx: *SkillContext,
        reason: EscalateReason,
        step: ?[]const u8,
        allocator: std.mem.Allocator,
    ) !void {
        if (self.metrics) |m| m.escalations += 1;
        if (self.on_escalate) |cb| try cb(ctx, reason, step, allocator);
    }

    fn runStep(self: Workflow, allocator: std.mem.Allocator, ctx: *SkillContext, step: Step) !StepOutcome {
        return switch (step.kind) {
            .llm => |s| blk: {
                const provider = self.provider orelse return error.ProviderRequired;
                var msgs = [_]AiProvider.ChatMsg{.{ .role = "user", .content = s.prompt }};
                if (self.budget) |b| {
                    if (!b.tryConsume(tokenizer.estimateMessages(&msgs))) return error.BudgetExhausted;
                }
                var resp = try provider.chat(msgs[0..]);
                defer provider.freeResponse(&resp);
                break :blk .{ .output = try allocator.dupe(u8, resp.content) };
            },
            .skill => |s| blk: {
                const value = try self.registry.dispatch(s.name, ctx, s.args);
                defer skill_mod.freeValue(ctx.allocator, value);
                break :blk .{ .output = try std.json.Stringify.valueAlloc(allocator, value, .{}) };
            },
            .agent => |s| blk: {
                const provider = self.provider orelse return error.ProviderRequired;
                var agent = Agent{
                    .provider = provider,
                    .registry = self.registry,
                    .budget = self.budget,
                    .allowlist = self.allowlist,
                    .audit = self.audit,
                    .run_audit = self.run_audit,
                };
                var ar = try agent.run(allocator, s.goal, ctx, s.max_steps);
                defer ar.deinit(allocator);
                break :blk .{
                    .output = try allocator.dupe(u8, ar.answer),
                    .budget_exhausted = ar.budget_exhausted,
                };
            },
            .approval => |s| blk: {
                const flow = self.approval_flow orelse return error.ApprovalFlowRequired;
                const gate_steps = [_]approval_mod.ApprovalStep{.{ .name = step.name }};
                const request = if (s.request.len > 0) s.request else s.subject;
                var ar = try flow.submit(allocator, ctx, s.subject, s.amount, request, &gate_steps);
                defer ar.deinit(allocator);
                switch (ar.status) {
                    .approved => break :blk .{ .output = try allocator.dupe(u8, "approved") },
                    .rejected => return error.ApprovalRejected,
                    .pending_human => break :blk .{
                        .output = try std.json.Stringify.valueAlloc(allocator, .{
                            .status = "pending_human",
                            .run_id = ar.run_id,
                        }, .{}),
                        .pending_human = true,
                    },
                }
            },
        };
    }
};

test "workflow runs skill steps and records results" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var count: usize = 0;
    const T = struct {
        fn incr(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
            _ = args;
            const c: *usize = @ptrCast(@alignCast(ctx.userdata.?));
            c.* += 1;
            var out = std.json.ObjectMap{};
            try out.put(ctx.allocator, try ctx.allocator.dupe(u8, "count"), .{ .integer = @intCast(c.*) });
            return .{ .object = out };
        }
    };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{
        .name = "incr",
        .description = "increment",
        .parameters = &.{},
        .handler = T.incr,
    });

    var ctx = SkillContext{ .allocator = a, .userdata = @ptrCast(&count) };
    const steps = [_]Step{
        .{ .name = "step_a", .kind = .{ .skill = .{ .name = "incr", .args = .{ .object = .{} } } } },
        .{ .name = "step_b", .kind = .{ .skill = .{ .name = "incr", .args = .{ .object = .{} } } } },
    };
    var wf = Workflow.init(&registry, &steps);
    var result = try wf.run(allocator, &ctx);
    defer result.deinit();

    try std.testing.expectEqual(RunStatus.completed, result.status);
    try std.testing.expectEqual(@as(usize, 2), result.steps.items.len);
    try std.testing.expectEqual(StepStatus.completed, result.steps.items[1].status);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(std.mem.indexOf(u8, result.steps.items[1].output, "\"count\":2") != null);
}

test "workflow metrics track runs and escalations" {
    const allocator = std.testing.allocator;
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    const Ok = struct {
        fn h(ctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
            return .{ .string = try ctx.allocator.dupe(u8, "ok") };
        }
    };
    try registry.register(.{ .name = "ok", .description = "", .parameters = &.{}, .handler = Ok.h });
    const Fail = struct {
        fn h(_: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
            return error.Boom;
        }
    };
    try registry.register(.{ .name = "boom", .description = "", .parameters = &.{}, .handler = Fail.h });

    var metrics = WorkflowMetrics{};
    var ctx = SkillContext{ .allocator = allocator };

    const good_steps = [_]Step{
        .{ .name = "a", .kind = .{ .skill = .{ .name = "ok", .args = .{ .object = .{} } } } },
        .{ .name = "b", .kind = .{ .skill = .{ .name = "ok", .args = .{ .object = .{} } } } },
    };
    var good = Workflow.init(&registry, &good_steps);
    good.metrics = &metrics;
    var good_result = try good.run(allocator, &ctx);
    defer good_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), metrics.runs);
    try std.testing.expectEqual(@as(usize, 2), metrics.completed_steps);

    const bad_steps = [_]Step{
        .{ .name = "a", .kind = .{ .skill = .{ .name = "ok", .args = .{ .object = .{} } } } },
        .{ .name = "bad", .kind = .{ .skill = .{ .name = "boom", .args = .{ .object = .{} } } }, .retry = 1 },
    };
    var bad = Workflow.init(&registry, &bad_steps);
    bad.metrics = &metrics;
    var bad_result = try bad.run(allocator, &ctx);
    defer bad_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), metrics.runs);
    try std.testing.expectEqual(@as(usize, 1), metrics.failed_steps);
    try std.testing.expectEqual(@as(usize, 1), metrics.escalations);
}

test "workflow toMermaid renders linear and DAG graphs" {
    const allocator = std.testing.allocator;
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    const steps = [_]Step{
        .{ .name = "a", .kind = .{ .skill = .{ .name = "x", .args = .{ .object = .{} } } } },
        .{ .name = "b", .kind = .{ .skill = .{ .name = "x", .args = .{ .object = .{} } } }, .depends_on = &.{"a"} },
    };
    const wf = Workflow.init(&registry, &steps);
    const m = try wf.toMermaid(allocator);
    defer allocator.free(m);
    try std.testing.expect(std.mem.indexOf(u8, m, "flowchart TD") != null);
    try std.testing.expect(std.mem.indexOf(u8, m, "a --> b") != null);
}

test "workflow runs a DAG respecting dependencies" {
    const allocator = std.testing.allocator;
    var order = std.ArrayList(u8).empty;
    defer order.deinit(allocator);

    const T = struct {
        fn make(comptime tag: u8) *const fn (*SkillContext, std.json.Value) anyerror!std.json.Value {
            return struct {
                fn h(ctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
                    const o: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx.userdata.?));
                    try o.append(std.testing.allocator, tag);
                    return .{ .string = try ctx.allocator.dupe(u8, "ok") };
                }
            }.h;
        }
    };

    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{ .name = "sa", .description = "", .parameters = &.{}, .handler = T.make('A') });
    try registry.register(.{ .name = "sb", .description = "", .parameters = &.{}, .handler = T.make('B') });
    try registry.register(.{ .name = "sc", .description = "", .parameters = &.{}, .handler = T.make('C') });

    // C depends on A and B; A and B independent — wave1 A then B (declaration order among ready), then C.
    const steps = [_]Step{
        .{ .name = "c", .kind = .{ .skill = .{ .name = "sc", .args = .{ .object = .{} } } }, .depends_on = &.{ "a", "b" } },
        .{ .name = "a", .kind = .{ .skill = .{ .name = "sa", .args = .{ .object = .{} } } } },
        .{ .name = "b", .kind = .{ .skill = .{ .name = "sb", .args = .{ .object = .{} } } } },
    };
    var ctx = SkillContext{ .allocator = allocator, .userdata = @ptrCast(&order) };
    var wf = Workflow.init(&registry, &steps);
    var result = try wf.run(allocator, &ctx);
    defer result.deinit();
    try std.testing.expectEqual(RunStatus.completed, result.status);
    try std.testing.expectEqualStrings("ABC", order.items);
}

test "workflow detects cyclic dependencies" {
    const allocator = std.testing.allocator;
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    const Ok = struct {
        fn h(ctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
            return .{ .string = try ctx.allocator.dupe(u8, "ok") };
        }
    };
    try registry.register(.{ .name = "ok", .description = "", .parameters = &.{}, .handler = Ok.h });
    const steps = [_]Step{
        .{ .name = "a", .kind = .{ .skill = .{ .name = "ok", .args = .{ .object = .{} } } }, .depends_on = &.{"b"} },
        .{ .name = "b", .kind = .{ .skill = .{ .name = "ok", .args = .{ .object = .{} } } }, .depends_on = &.{"a"} },
    };
    var ctx = SkillContext{ .allocator = allocator };
    var wf = Workflow.init(&registry, &steps);
    try std.testing.expectError(error.CyclicDependency, wf.run(allocator, &ctx));
}

test "workflow parallel DAG wave completes dependents" {
    const allocator = std.testing.allocator;
    var hits = std.atomic.Value(usize).init(0);
    const T = struct {
        fn h(ctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
            const c: *std.atomic.Value(usize) = @ptrCast(@alignCast(ctx.userdata.?));
            _ = c.fetchAdd(1, .monotonic);
            return .{ .string = try ctx.allocator.dupe(u8, "ok") };
        }
    };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{ .name = "hit", .description = "", .parameters = &.{}, .handler = T.h });

    const steps = [_]Step{
        .{ .name = "c", .kind = .{ .skill = .{ .name = "hit", .args = .{ .object = .{} } } }, .depends_on = &.{ "a", "b" } },
        .{ .name = "a", .kind = .{ .skill = .{ .name = "hit", .args = .{ .object = .{} } } } },
        .{ .name = "b", .kind = .{ .skill = .{ .name = "hit", .args = .{ .object = .{} } } } },
    };
    var ctx = SkillContext{ .allocator = allocator, .userdata = @ptrCast(&hits) };
    var wf = Workflow.init(&registry, &steps);
    wf.io = std.testing.io;
    wf.max_parallel = 4;
    var result = try wf.run(allocator, &ctx);
    defer result.deinit();
    try std.testing.expectEqual(RunStatus.completed, result.status);
    try std.testing.expectEqual(@as(usize, 3), hits.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 3), result.steps.items.len);
}

test "workflow checkpoint resume skips completed steps" {
    const allocator = std.testing.allocator;
    var count: usize = 0;
    const T = struct {
        fn incr(ctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
            const c: *usize = @ptrCast(@alignCast(ctx.userdata.?));
            c.* += 1;
            return .{ .string = try ctx.allocator.dupe(u8, "ok") };
        }
    };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{ .name = "incr", .description = "", .parameters = &.{}, .handler = T.incr });

    const steps = [_]Step{
        .{ .name = "a", .kind = .{ .skill = .{ .name = "incr", .args = .{ .object = .{} } } } },
        .{ .name = "b", .kind = .{ .skill = .{ .name = "incr", .args = .{ .object = .{} } } } },
    };
    var ctx = SkillContext{ .allocator = allocator, .userdata = @ptrCast(&count) };
    var wf = Workflow.init(&registry, &steps);

    // Partial checkpoint: only step a done.
    const ck =
        \\{"status":"completed","steps":[{"name":"a","status":"completed","output":"\"ok\"","error_message":null}]}
    ;
    var result = try wf.runFromCheckpoint(allocator, &ctx, ck);
    defer result.deinit();
    try std.testing.expectEqual(RunStatus.completed, result.status);
    try std.testing.expectEqual(@as(usize, 2), result.steps.items.len);
    try std.testing.expectEqual(@as(usize, 1), count); // only b ran

    const dumped = try Workflow.dumpCheckpoint(&result, allocator);
    defer allocator.free(dumped);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "\"name\":\"b\"") != null);

    const path = "zfinal-test-workflow-checkpoint.json";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try Workflow.saveCheckpoint(&result, allocator, std.testing.io, path);
    var loaded = try Workflow.loadCheckpointFile(allocator, std.testing.io, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.steps.items.len);
}

test "workflow approval step gates on human decision" {
    const allocator = std.testing.allocator;
    const Policy = struct {
        fn decide(_: std.mem.Allocator, _: *SkillContext, _: []const u8, amount: i64, _: usize, _: []const u8, _: []const u8, _: *[]const u8) anyerror!approval_mod.ApprovalDecision {
            return if (amount <= 1000) .approved else .escalated;
        }
    };
    var flow = approval_mod.ApprovalFlow.init(allocator, std.testing.io, Policy.decide);
    defer flow.deinit();
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    var ctx = SkillContext{ .allocator = allocator };

    const ok_steps = [_]Step{
        .{ .name = "review", .kind = .{ .approval = .{ .subject = "order-1", .amount = 100 } } },
    };
    var ok_wf = Workflow.init(&registry, &ok_steps);
    ok_wf.approval_flow = &flow;
    var ok_result = try ok_wf.run(allocator, &ctx);
    defer ok_result.deinit();
    try std.testing.expectEqual(RunStatus.completed, ok_result.status);

    const gate_steps = [_]Step{
        .{ .name = "review", .kind = .{ .approval = .{ .subject = "order-2", .amount = 99999 } } },
        .{ .name = "after", .kind = .{ .skill = .{ .name = "noop", .args = .{ .object = .{} } } } },
    };
    var gate_wf = Workflow.init(&registry, &gate_steps);
    gate_wf.approval_flow = &flow;
    var gate_result = try gate_wf.run(allocator, &ctx);
    defer gate_result.deinit();
    try std.testing.expectEqual(RunStatus.pending_human, gate_result.status);
    try std.testing.expectEqual(@as(usize, 1), gate_result.steps.items.len);
    try std.testing.expectEqual(StepStatus.pending_human, gate_result.steps.items[0].status);
}

test "workflow approval gate resumes after pending_human checkpoint" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var flow = approval_mod.ApprovalFlow.init(allocator, std.testing.io, approval_mod.defaultPolicy);
    defer flow.deinit();

    var hits: usize = 0;
    const T = struct {
        fn h(ctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
            const c: *usize = @ptrCast(@alignCast(ctx.userdata.?));
            c.* += 1;
            return .{ .string = try ctx.allocator.dupe(u8, "ok") };
        }
    };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{ .name = "publish", .description = "", .parameters = &.{}, .handler = T.h });

    var ctx = SkillContext{ .allocator = a, .userdata = @ptrCast(&hits) };
    const steps = [_]Step{
        .{ .name = "review", .kind = .{ .approval = .{ .subject = "order-9", .amount = 50000 } } },
        .{ .name = "publish", .kind = .{ .skill = .{ .name = "publish", .args = .{ .object = .{} } } } },
    };
    var wf = Workflow.init(&registry, &steps);
    wf.approval_flow = &flow;

    var first = try wf.run(allocator, &ctx);
    defer first.deinit();
    try std.testing.expectEqual(RunStatus.pending_human, first.status);
    try std.testing.expectEqual(@as(usize, 0), hits);

    const ck = try Workflow.dumpCheckpoint(&first, allocator);
    defer allocator.free(ck);
    const rid = try allocator.dupe(u8, flow.pending.items[0].run_id);
    defer allocator.free(rid);
    try std.testing.expect(flow.resolve(rid, true));

    var resumed = try wf.runFromCheckpoint(allocator, &ctx, ck);
    defer resumed.deinit();
    try std.testing.expectEqual(RunStatus.completed, resumed.status);
    try std.testing.expectEqual(@as(usize, 1), hits);
    try std.testing.expectEqual(@as(usize, 2), resumed.steps.items.len);
}

test "workflow approval gate stays pending until resolved" {
    const allocator = std.testing.allocator;
    var flow = approval_mod.ApprovalFlow.init(allocator, std.testing.io, approval_mod.defaultPolicy);
    defer flow.deinit();
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    var ctx = SkillContext{ .allocator = allocator };
    const steps = [_]Step{
        .{ .name = "review", .kind = .{ .approval = .{ .subject = "wait", .amount = 1 } } },
    };
    var wf = Workflow.init(&registry, &steps);
    wf.approval_flow = &flow;
    var first = try wf.run(allocator, &ctx);
    defer first.deinit();
    const ck = try Workflow.dumpCheckpoint(&first, allocator);
    defer allocator.free(ck);

    var still = try wf.runFromCheckpoint(allocator, &ctx, ck);
    defer still.deinit();
    try std.testing.expectEqual(RunStatus.pending_human, still.status);
}

test "workflow approval gate reject fails resume" {
    const allocator = std.testing.allocator;
    var hits: usize = 0;
    const T = struct {
        fn h(ctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
            const c: *usize = @ptrCast(@alignCast(ctx.userdata.?));
            c.* += 1;
            return .{ .string = try ctx.allocator.dupe(u8, "ok") };
        }
    };
    var flow = approval_mod.ApprovalFlow.init(allocator, std.testing.io, approval_mod.defaultPolicy);
    defer flow.deinit();
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{ .name = "publish", .description = "", .parameters = &.{}, .handler = T.h });
    var ctx = SkillContext{ .allocator = allocator, .userdata = @ptrCast(&hits) };
    const steps = [_]Step{
        .{ .name = "review", .kind = .{ .approval = .{ .subject = "no", .amount = 1 } } },
        .{ .name = "publish", .kind = .{ .skill = .{ .name = "publish", .args = .{ .object = .{} } } } },
    };
    var wf = Workflow.init(&registry, &steps);
    wf.approval_flow = &flow;
    var first = try wf.run(allocator, &ctx);
    defer first.deinit();
    const ck = try Workflow.dumpCheckpoint(&first, allocator);
    defer allocator.free(ck);
    try std.testing.expect(flow.resolve(flow.pending.items[0].run_id, false));

    var resumed = try wf.runFromCheckpoint(allocator, &ctx, ck);
    defer resumed.deinit();
    try std.testing.expectEqual(RunStatus.failed, resumed.status);
    try std.testing.expectEqual(@as(usize, 0), hits);
}

test "workflow journal persists and resumeFromJournal continues" {
    const allocator = std.testing.allocator;
    const dir = "zfinal-test-wf-journal-resume";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var journal = try WorkflowJournal.init(allocator, std.testing.io, dir);
    defer journal.deinit();

    var hits: usize = 0;
    const T = struct {
        fn h(ctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
            const c: *usize = @ptrCast(@alignCast(ctx.userdata.?));
            c.* += 1;
            return .{ .string = try ctx.allocator.dupe(u8, "ok") };
        }
    };
    var flow = approval_mod.ApprovalFlow.init(allocator, std.testing.io, approval_mod.defaultPolicy);
    defer flow.deinit();
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{ .name = "publish", .description = "", .parameters = &.{}, .handler = T.h });

    var ctx = SkillContext{ .allocator = allocator, .userdata = @ptrCast(&hits) };
    const steps = [_]Step{
        .{ .name = "review", .kind = .{ .approval = .{ .subject = "j", .amount = 1 } } },
        .{ .name = "publish", .kind = .{ .skill = .{ .name = "publish", .args = .{ .object = .{} } } } },
    };
    var wf = Workflow.init(&registry, &steps);
    wf.approval_flow = &flow;
    wf.journal = &journal;
    wf.run_id = "jr-1";

    var first = try wf.run(allocator, &ctx);
    defer first.deinit();
    try std.testing.expectEqual(RunStatus.pending_human, first.status);

    const rid = try allocator.dupe(u8, flow.pending.items[0].run_id);
    defer allocator.free(rid);
    try std.testing.expect(flow.resolve(rid, true));

    var resumed = try wf.resumeFromJournal(allocator, &ctx, "jr-1");
    defer resumed.deinit();
    try std.testing.expectEqual(RunStatus.completed, resumed.status);
    try std.testing.expectEqual(@as(usize, 1), hits);
}

test "workflow toMermaid annotates approval steps" {
    const allocator = std.testing.allocator;
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    const steps = [_]Step{
        .{ .name = "a", .kind = .{ .skill = .{ .name = "x", .args = .{ .object = .{} } } } },
        .{ .name = "b", .kind = .{ .approval = .{ .subject = "x", .amount = 1 } } },
    };
    const wf = Workflow.init(&registry, &steps);
    const m = try wf.toMermaid(allocator);
    defer allocator.free(m);
    try std.testing.expect(std.mem.indexOf(u8, m, "b[\"b (approval)\"]") != null);
}
