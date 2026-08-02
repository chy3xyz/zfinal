//! Offline demo of `zfinal.ai`: Workflow + Agent + business skills + approval.
//! No live LLM — safe for CI / local smoke: `zig build run-ai-runtime`.

const std = @import("std");
const zfinal = @import("zfinal");

fn ping(ctx: *zfinal.ai.SkillContext, _: std.json.Value) anyerror!std.json.Value {
    return .{ .string = try ctx.allocator.dupe(u8, "pong") };
}

fn echo(ctx: *zfinal.ai.SkillContext, args: std.json.Value) anyerror!std.json.Value {
    const text = if (args == .object)
        if (args.object.get("text")) |v| switch (v) {
            .string => |s| s,
            else => "?",
        } else "?"
    else
        "?";
    return .{ .string = try ctx.allocator.dupe(u8, text) };
}

const MockChat = struct {
    allocator: std.mem.Allocator,
    step: usize = 0,

    fn chat(ctx: *anyopaque, _: []const zfinal.ai.AiProvider.ChatMsg, _: zfinal.ai.AiProvider.ChatOpts) anyerror!zfinal.ai.AiProvider.ChatResponse {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.step += 1;
        if (self.step == 1) {
            const tcs = try self.allocator.alloc(zfinal.ai.AiProvider.ToolCall, 1);
            tcs[0] = .{
                .id = try self.allocator.dupe(u8, "1"),
                .name = try self.allocator.dupe(u8, "ping"),
                .arguments = try self.allocator.dupe(u8, "{}"),
            };
            return .{ .content = try self.allocator.dupe(u8, ""), .tool_calls = tcs };
        }
        return .{ .content = try self.allocator.dupe(u8, "Agent finished: pong") };
    }
};

pub fn main(init: std.process.Init) !void {
    @import("zfinal").io_instance.init(init);
    const allocator = init.gpa;
    const io = init.io;

    // ── Skills registry ──────────────────────────────────────────────
    var registry = zfinal.ai.SkillRegistry.init(allocator, io);
    defer registry.deinit();
    try registry.register(.{
        .name = "ping",
        .description = "Health check",
        .parameters = &.{},
        .handler = ping,
    });
    try registry.register(.{
        .name = "echo",
        .description = "Echo text",
        .parameters = &.{.{ .name = "text", .type = .string, .description = "text", .required = true }},
        .handler = echo,
    });
    try zfinal.ai.registerBusinessSkills(&registry);
    try zfinal.ai.registerApprovalSkills(&registry);
    try zfinal.ai.registerMemorySkills(&registry);

    // ── In-memory SQLite + business ctx ──────────────────────────────
    var db = try zfinal.DB.init(allocator, zfinal.DBConfig.sqliteMemory());
    defer db.destroy();
    try db.exec(
        \\CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT, tenant_id INTEGER);
        \\INSERT INTO products (id, name, tenant_id) VALUES (1, 'widget', 7);
        \\INSERT INTO products (id, name, tenant_id) VALUES (2, 'gadget', 8);
    );
    const entities = [_]zfinal.ai.EntitySpec{
        .{ .name = "product", .table = "products", .pk = "id", .tenant_column = "tenant_id" },
    };
    var biz = zfinal.ai.BusinessCtx{ .db = db, .entities = &entities };

    // ── Approval + memory ────────────────────────────────────────────
    var flow = zfinal.ai.ApprovalFlow.init(allocator, io, zfinal.ai.defaultApprovalPolicy);
    defer flow.deinit();
    try flow.attachDb(db);
    const ap_steps = [_]zfinal.ai.ApprovalStep{.{ .name = "manager" }};
    var ap_ctx = zfinal.ai.ApprovalCtx{ .flow = &flow, .steps = &ap_steps };

    var memory = zfinal.ai.MemoryStore.init(allocator, io);
    defer memory.deinit();

    var run_audit = try zfinal.ai.RunAuditStore.init(allocator, io, 64);
    defer run_audit.deinit();
    try run_audit.attachDb(db);

    var quota = zfinal.ai.TokenQuota.init(allocator, io, 100_000);
    defer quota.deinit();
    try quota.attachDb(db);
    try quota.setLimit(7, 50_000);

    var tool_audit = try zfinal.ai.AgentAuditLog.init(allocator, io, 128);
    defer tool_audit.deinit();
    try tool_audit.attachDb(db);

    // ── Workflow ─────────────────────────────────────────────────────
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var echo_args = std.json.ObjectMap{};
    try echo_args.put(aa, try aa.dupe(u8, "text"), .{ .string = "hello-wf" });
    const wf_steps = [_]zfinal.ai.Step{
        .{ .name = "ping_step", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } } },
        .{ .name = "echo_step", .kind = .{ .skill = .{ .name = "echo", .args = .{ .object = echo_args } } }, .depends_on = &.{"ping_step"} },
    };

    var wf = zfinal.ai.Workflow.init(&registry, &wf_steps);
    wf.run_audit = &run_audit;
    var skill_ctx = zfinal.ai.SkillContext{ .allocator = aa, .run_id = "demo-wf" };
    var wf_result = try wf.run(allocator, &skill_ctx);
    defer wf_result.deinit();
    std.debug.print("workflow status={s} steps={d} last={s}\n", .{
        @tagName(wf_result.status),
        wf_result.steps.items.len,
        if (wf_result.steps.items.len > 0) wf_result.steps.items[wf_result.steps.items.len - 1].output else "",
    });

    const mermaid = try wf.toMermaid(allocator);
    defer allocator.free(mermaid);
    std.debug.print("{s}\n", .{mermaid});

    // ── Business: entity.lookup (tenant-scoped) ───────────────────────
    var biz_ctx = zfinal.ai.SkillContext{
        .allocator = allocator,
        .userdata = @ptrCast(&biz),
        .tenant_id = 7,
    };
    var lookup_args = std.json.ObjectMap{};
    defer lookup_args.deinit(allocator);
    try lookup_args.put(allocator, "entity", .{ .string = "product" });
    try lookup_args.put(allocator, "id", .{ .integer = 1 });
    const lookup = try registry.dispatch("entity.lookup", &biz_ctx, .{ .object = lookup_args });
    defer zfinal.ai.freeValue(allocator, lookup);
    std.debug.print("entity.lookup product#1 name={s}\n", .{lookup.object.get("name").?.string});

    var qargs = std.json.ObjectMap{};
    defer qargs.deinit(allocator);
    try qargs.put(allocator, "sql", .{ .string = "SELECT id, name FROM products WHERE tenant_id = ?" });
    var qarr = std.json.Array.init(allocator);
    defer qarr.deinit();
    try qarr.append(.{ .integer = 7 });
    try qargs.put(allocator, "args", .{ .array = qarr });
    const qres = try registry.dispatch("db.query", &biz_ctx, .{ .object = qargs });
    defer zfinal.ai.freeValue(allocator, qres);
    std.debug.print("db.query count={d}\n", .{qres.object.get("count").?.integer});

    // ── Approval: submit → pending → resolve ─────────────────────────
    var ap_skill_ctx = zfinal.ai.SkillContext{ .allocator = allocator, .userdata = @ptrCast(&ap_ctx) };
    var sub_args = std.json.ObjectMap{};
    defer sub_args.deinit(allocator);
    try sub_args.put(allocator, "subject", .{ .string = "order-42" });
    try sub_args.put(allocator, "amount", .{ .integer = 1999 });
    try sub_args.put(allocator, "request", .{ .string = "refund demo" });
    const sub = try registry.dispatch("approval.submit", &ap_skill_ctx, .{ .object = sub_args });
    defer zfinal.ai.freeValue(allocator, sub);
    const run_id = sub.object.get("run_id").?.string;
    std.debug.print("approval.submit status={s} run_id={s}\n", .{ sub.object.get("status").?.string, run_id });

    const pending = try registry.dispatch("approval.list_pending", &ap_skill_ctx, .{ .object = .{} });
    defer zfinal.ai.freeValue(allocator, pending);
    std.debug.print("approval.pending len={d}\n", .{pending.object.get("pending").?.array.items.len});

    var res_args = std.json.ObjectMap{};
    defer res_args.deinit(allocator);
    try res_args.put(allocator, "run_id", .{ .string = run_id });
    try res_args.put(allocator, "approve", .{ .bool = true });
    const resolved = try registry.dispatch("approval.resolve", &ap_skill_ctx, .{ .object = res_args });
    defer zfinal.ai.freeValue(allocator, resolved);
    std.debug.print("approval.resolve ok={any}\n", .{resolved.object.get("ok").?.bool});

    // ── Workflow approval gate (pending_human) ────────────────────────
    const gate_steps = [_]zfinal.ai.Step{
        .{ .name = "review", .kind = .{ .approval = .{ .subject = "order-gate", .amount = 50000, .request = "large refund" } } },
        .{ .name = "publish", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } } },
    };
    var gate_wf = zfinal.ai.Workflow.init(&registry, &gate_steps);
    gate_wf.approval_flow = &flow;
    gate_wf.run_audit = &run_audit;
    var gate_ctx = zfinal.ai.SkillContext{ .allocator = aa, .run_id = "demo-gate" };
    var gate_first = try gate_wf.run(allocator, &gate_ctx);
    defer gate_first.deinit();
    std.debug.print("workflow.approval status={s} steps={d}\n", .{
        @tagName(gate_first.status),
        gate_first.steps.items.len,
    });
    const gate_ck = try zfinal.ai.Workflow.dumpCheckpoint(&gate_first, allocator);
    defer allocator.free(gate_ck);
    var pending_list = std.ArrayList(zfinal.ai.PendingItem).empty;
    defer {
        for (pending_list.items) |p| {
            allocator.free(p.run_id);
            allocator.free(p.subject);
            allocator.free(p.request);
            allocator.free(p.step_name);
        }
        pending_list.deinit(allocator);
    }
    try flow.listPending(allocator, &pending_list, null);
    if (pending_list.items.len > 0) {
        _ = flow.resolve(pending_list.items[0].run_id, true);
    }
    var gate_resumed = try gate_wf.runFromCheckpoint(allocator, &gate_ctx, gate_ck);
    defer gate_resumed.deinit();
    std.debug.print("workflow.approval resumed={s} steps={d}\n", .{
        @tagName(gate_resumed.status),
        gate_resumed.steps.items.len,
    });

    // ── Memory skill ─────────────────────────────────────────────────
    var mem_ctx = zfinal.ai.SkillContext{
        .allocator = allocator,
        .userdata = @ptrCast(&memory),
        .tenant_id = 7,
        .user_id = 1,
    };
    var mem_args = std.json.ObjectMap{};
    defer mem_args.deinit(allocator);
    try mem_args.put(allocator, "key", .{ .string = "lang" });
    try mem_args.put(allocator, "value", .{ .string = "zh" });
    const mem_r = try registry.dispatch("memory_remember", &mem_ctx, .{ .object = mem_args });
    defer zfinal.ai.freeValue(allocator, mem_r);

    // ── Trigger ──────────────────────────────────────────────────────
    const TriggerRunner = struct {
        fn run(a: std.mem.Allocator, _: *zfinal.ai.SkillContext, input: []const u8, out: *zfinal.ai.TriggerResult) anyerror!void {
            out.ok = true;
            out.run_id = try a.dupe(u8, "trig-1");
            out.message = try a.dupe(u8, input);
        }
    };
    var trigger = zfinal.ai.Trigger.init(allocator, io, TriggerRunner.run, .{ .allocator = allocator });
    defer trigger.deinit();
    const tr = try trigger.fire(allocator, "order.paid");
    defer {
        allocator.free(tr.run_id);
        allocator.free(tr.message);
    }
    std.debug.print("trigger ok={any} message={s}\n", .{ tr.ok, tr.message });

    // ── Agent (chat_override) + ToolGate + run_audit ─────────────────
    var http = try zfinal.HttpClient.init(allocator, "");
    defer http.deinit();
    var provider = zfinal.ai.AiProvider.init(allocator, &http, "http://unused", "sk-test", "mock");
    defer provider.deinit();

    const gate = zfinal.ai.ToolGate{ .gated = &.{"db.query"} };
    var mock = MockChat{ .allocator = allocator };
    var agent = zfinal.ai.Agent{
        .provider = &provider,
        .registry = &registry,
        .allowlist = &.{"ping"},
        .chat_override = MockChat.chat,
        .chat_override_ctx = &mock,
        .run_audit = &run_audit,
        .audit = &tool_audit,
        .hooks = .{
            .ctx = @ptrCast(@constCast(&gate)),
            .on_tool_request = zfinal.ai.ToolGate.hook,
        },
    };
    var agent_ctx = zfinal.ai.SkillContext{ .allocator = allocator, .run_id = "demo-agent" };
    var agent_result = try agent.run(allocator, "please ping", &agent_ctx, 5);
    defer agent_result.deinit(allocator);
    std.debug.print("agent answer={s} steps={d}\n", .{ agent_result.answer, agent_result.steps });
    std.debug.print("toolgate(db.query)={s} toolgate(ping)={s}\n", .{
        @tagName(gate.onRequest("db.query")),
        @tagName(gate.onRequest("ping")),
    });

    const audit_json = try run_audit.dumpJson(allocator);
    defer allocator.free(audit_json);
    std.debug.print("run_audit entries={d} json={s}\n", .{ run_audit.count, audit_json });
    std.debug.print("quota tenant7 remaining={d} tool_audit={d}\n", .{ quota.remaining(7), tool_audit.count });

    const catalog = try zfinal.ai.toSkillsJson(&registry, allocator);
    defer allocator.free(catalog);
    std.debug.print("skills catalog bytes={d}\n", .{catalog.len});

    std.debug.print("ok — see doc/ai.md (business / approval / trigger / live: run-ai-live)\n", .{});
}
