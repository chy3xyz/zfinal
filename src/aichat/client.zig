const std = @import("std");
const io_instance = @import("../io_instance.zig");
const types = @import("types.zig");
const ChatMessage = types.ChatMessage;
const ChatResult = types.ChatResult;

pub const AiClient = struct {
    context: *anyopaque,
    chatSync: *const fn (
        ctx: *anyopaque,
        api_url: []const u8,
        api_key: []const u8,
        model: []const u8,
        messages: []const ChatMessage,
        temperature: f64,
        max_tokens: i64,
        allocator: std.mem.Allocator,
    ) anyerror!ChatResult,

    chatStream: *const fn (
        ctx: *anyopaque,
        api_url: []const u8,
        api_key: []const u8,
        model: []const u8,
        messages: []const ChatMessage,
        temperature: f64,
        max_tokens: i64,
        allocator: std.mem.Allocator,
    ) anyerror![]const []const u8,

    deinit: *const fn (ctx: *anyopaque) void,
};

pub fn chatSync(client: AiClient, api_url: []const u8, api_key: []const u8, model: []const u8, messages: []const ChatMessage, temperature: f64, max_tokens: i64, allocator: std.mem.Allocator) !ChatResult {
    return try client.chatSync(client.context, api_url, api_key, model, messages, temperature, max_tokens, allocator);
}

pub fn chatStream(client: AiClient, api_url: []const u8, api_key: []const u8, model: []const u8, messages: []const ChatMessage, temperature: f64, max_tokens: i64, allocator: std.mem.Allocator) ![]const []const u8 {
    return try client.chatStream(client.context, api_url, api_key, model, messages, temperature, max_tokens, allocator);
}

pub fn deinitClient(client: AiClient) void {
    client.deinit(client.context);
}

pub const CurlAiClient = struct {
    context: *anyopaque,

    pub fn init() CurlAiClient {
        return .{ .context = undefined };
    }

    pub fn client(self: *CurlAiClient) AiClient {
        return .{
            .context = self,
            .chatSync = doSync,
            .chatStream = doStream,
            .deinit = doDeinit,
        };
    }

    fn doDeinit(_: *anyopaque) void {}

    fn doSync(
        _: *anyopaque,
        api_url: []const u8,
        api_key: []const u8,
        model: []const u8,
        messages: []const ChatMessage,
        temperature: f64,
        max_tokens: i64,
        allocator: std.mem.Allocator,
    ) !ChatResult {
        const body = try std.json.Stringify.valueAlloc(allocator, .{
            .model = model,
            .messages = messages,
            .stream = false,
            .temperature = temperature,
            .max_tokens = max_tokens,
        }, .{});
        defer allocator.free(body);

        const resp = try postJsonCurl(api_url, "/v1/chat/completions", api_key, body, allocator);
        defer {
            allocator.free(resp.stdout);
            allocator.free(resp.stderr);
        }

        if (resp.exit_code != 0) {
            return error.ConnectionFailed;
        }

        const parsed = try std.json.parseFromSlice(struct {
            choices: []struct {
                message: struct {
                    content: []const u8,
                },
            },
            usage: ?struct {
                prompt_tokens: ?i64,
                completion_tokens: ?i64,
                total_tokens: ?i64,
            } = null,
            model: ?[]const u8 = null,
        }, allocator, resp.stdout, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const choice = if (parsed.value.choices.len > 0) parsed.value.choices[0] else return error.NoChoice;
        const content = try allocator.dupe(u8, choice.message.content);

        return .{
            .content = content,
            .model_name = if (parsed.value.model) |m| try allocator.dupe(u8, m) else null,
            .prompt_tokens = parsed.value.usage.?.prompt_tokens orelse 0,
            .completion_tokens = parsed.value.usage.?.completion_tokens orelse 0,
            .total_tokens = parsed.value.usage.?.total_tokens orelse 0,
        };
    }

    fn doStream(
        _: *anyopaque,
        api_url: []const u8,
        api_key: []const u8,
        model: []const u8,
        messages: []const ChatMessage,
        temperature: f64,
        max_tokens: i64,
        allocator: std.mem.Allocator,
    ) ![]const []const u8 {
        const body = try std.json.Stringify.valueAlloc(allocator, .{
            .model = model,
            .messages = messages,
            .stream = true,
            .temperature = temperature,
            .max_tokens = max_tokens,
        }, .{});
        defer allocator.free(body);

        const full_url = try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{api_url});
        defer allocator.free(full_url);

        const auth_hdr = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
        defer allocator.free(auth_hdr);

        const sh_cmd = try std.mem.concat(allocator, u8, &.{
            \\ printf '%s' '
            , body,
            \\ ' > /tmp/aichat_req.json && curl -s --compressed -XPOST 
            , full_url,
            \\ -H 'Content-Type: application/json' -H '
            , auth_hdr,
            \\ ' -d @/tmp/aichat_req.json -m 120 -k
        });
        defer allocator.free(sh_cmd);

        const run_result = std.process.run(allocator, io_instance.io, .{
            .argv = &.{ "sh", "-c", sh_cmd },
        }) catch return error.ConnectionFailed;

        defer {
            allocator.free(run_result.stdout);
            allocator.free(run_result.stderr);
        }

        var tokens = std.ArrayList([]const u8).empty;
        errdefer {
            for (tokens.items) |t| allocator.free(t);
            tokens.deinit(allocator);
        }

        var spliter = std.mem.splitScalar(u8, run_result.stdout, '\n');
        while (spliter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\r");
            if (trimmed.len > 0 and trimmed[0] == 'd' and std.mem.startsWith(u8, trimmed, "data:")) {
                const content = std.mem.trim(u8, trimmed[5..], " ");
                if (!std.mem.startsWith(u8, content, "[DONE]") and content.len > 0) {
                    const parsed_token = std.json.parseFromSlice(struct {
                        choices: []struct {
                            delta: struct {
                                content: ?[]const u8 = null,
                            },
                        },
                    }, allocator, content, .{
                        .allocate = .alloc_always,
                        .ignore_unknown_fields = true,
                    }) catch continue;
                    defer parsed_token.deinit();
                    if (parsed_token.value.choices.len > 0 and
                        parsed_token.value.choices[0].delta.content != null)
                    {
                        try tokens.append(allocator, try allocator.dupe(u8, parsed_token.value.choices[0].delta.content.?));
                    }
                }
            }
        }

        return try tokens.toOwnedSlice(allocator);
    }
};

const CurlResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

fn postJsonCurl(
    api_url: []const u8,
    path: []const u8,
    api_key: []const u8,
    body: []const u8,
    allocator: std.mem.Allocator,
) !CurlResult {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ api_url, path });
    defer allocator.free(url);

    const auth_hdr = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    defer allocator.free(auth_hdr);

    const sh_cmd = try std.mem.concat(allocator, u8, &.{
        \\ curl -s -XPOST 
        , url,
        \\ -H 'Content-Type: application/json' -H '
        , auth_hdr,
        \\ ' -d '
        , body,
        \\ ' --max-time 15 -k
    });
    defer allocator.free(sh_cmd);

    const result = std.process.run(allocator, io_instance.io, .{
        .argv = &.{ "sh", "-c", sh_cmd },
    }) catch return error.ConnectionFailed;

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = if (result.term == .exited) result.term.exited else 255,
    };
}
