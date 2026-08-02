//! Live LLM demo for `zfinal.ai` (needs network + API key).
//!
//! ```bash
//! export OPENAI_API_KEY=sk-...
//! # optional:
//! # export OPENAI_BASE_URL=https://api.openai.com/v1   # → …/chat/completions
//! # export OPENAI_MODEL=gpt-4o-mini
//! # export OPENAI_STREAM=1   # print chatStream deltas then exit
//! zig build run-ai-live -- "Use get_time, then say hello"
//! ```

const std = @import("std");
const zfinal = @import("zfinal");

fn getTime(ctx: *zfinal.ai.SkillContext, _: std.json.Value) anyerror!std.json.Value {
    const ms = zfinal.ai.time_util.nowMillis();
    const buf = try std.fmt.allocPrint(ctx.allocator, "{d}", .{ms});
    return .{ .string = buf };
}

fn envOr(name: [*:0]const u8, fallback: []const u8) []const u8 {
    if (std.c.getenv(name)) |p| {
        const s = std.mem.span(p);
        if (s.len > 0) return s;
    }
    return fallback;
}

fn buildEndpoint(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("OPENAI_ENDPOINT")) |p| {
        const s = std.mem.span(p);
        if (s.len > 0) return try allocator.dupe(u8, s);
    }
    const base = envOr("OPENAI_BASE_URL", "https://api.openai.com/v1");
    if (std.mem.endsWith(u8, base, "/chat/completions")) {
        return try allocator.dupe(u8, base);
    }
    if (std.mem.endsWith(u8, base, "/")) {
        return try std.fmt.allocPrint(allocator, "{s}chat/completions", .{base});
    }
    return try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{base});
}

pub fn main(init: std.process.Init) !void {
    @import("zfinal").io_instance.init(init);
    const allocator = init.gpa;

    const api_key = blk: {
        const p = std.c.getenv("OPENAI_API_KEY") orelse {
            std.debug.print(
                \\missing OPENAI_API_KEY
                \\usage:
                \\  export OPENAI_API_KEY=sk-...
                \\  zig build run-ai-live -- "your goal"
                \\
            , .{});
            return error.MissingApiKey;
        };
        break :blk std.mem.span(p);
    };
    if (api_key.len == 0) return error.MissingApiKey;

    const endpoint = try buildEndpoint(allocator);
    defer allocator.free(endpoint);
    const model = envOr("OPENAI_MODEL", "gpt-4o-mini");
    const stream_only = std.c.getenv("OPENAI_STREAM") != null;

    var goal: []const u8 = "Call get_time, then reply with the unix-ms timestamp and a one-line greeting.";
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_it.deinit();
    _ = arg_it.skip(); // argv0
    // `zig build run-ai-live -- "goal"` may pass a lone `--` before the goal.
    while (arg_it.next()) |a| {
        if (std.mem.eql(u8, a, "--")) continue;
        goal = a;
        break;
    }

    std.debug.print("endpoint={s} model={s}\n", .{ endpoint, model });

    var runtime = try zfinal.ai.AiRuntime.init(allocator, init.io, .{
        .endpoint = endpoint,
        .api_key = api_key,
        .model = model,
        .enable_audit = true,
        .system_prompt = "You are a helpful agent. Prefer tools for facts. When finished, reply with the final answer only.",
        .max_steps = 6,
        .tool_timeout_ms = 10_000,
    });
    defer runtime.deinit();

    try runtime.register(.{
        .name = "get_time",
        .description = "Return current unix time in milliseconds",
        .parameters = &.{},
        .handler = getTime,
    });

    if (stream_only) {
        const StreamCtx = struct {
            fn onDelta(_: *anyopaque, d: zfinal.ai.AiProvider.StreamDelta) anyerror!void {
                if (d.content_delta) |c| std.debug.print("{s}", .{c});
            }
        };
        const msgs = [_]zfinal.ai.AiProvider.ChatMsg{
            .{ .role = "user", .content = goal },
        };
        var resp = try runtime.provider.chatStream(&msgs, .{}, @ptrFromInt(1), StreamCtx.onDelta);
        defer runtime.provider.freeResponse(&resp);
        std.debug.print("\n[stream done tokens≈{d}+{d}]\n", .{ resp.prompt_tokens, resp.completion_tokens });
        return;
    }

    var skill_ctx = zfinal.ai.SkillContext{ .allocator = allocator };
    const allow = [_][]const u8{"get_time"};
    var result = try runtime.run(goal, &skill_ctx, &allow);
    defer result.deinit(allocator);

    std.debug.print("answer={s}\nsteps={d}\n", .{ result.answer, result.steps });
    if (runtime.audit) |*audit| {
        std.debug.print("audit_events={d}\n", .{audit.count});
    }
}
