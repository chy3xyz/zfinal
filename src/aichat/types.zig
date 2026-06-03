const std = @import("std");

pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub const ChatResult = struct {
    content: []const u8,
    model_name: ?[]const u8 = null,
    prompt_tokens: i64 = 0,
    completion_tokens: i64 = 0,
    total_tokens: i64 = 0,
};

pub const SYSTEM_PROMPT_TEMPLATE =
    "你是一个AI驱动的助手，帮助用户完成各种任务。\n" ++
    "\n" ++
    "**重要：当前日期时间信息**\n" ++
    "- 今天是：%s\n" ++
    "- 日期格式统一使用：yyyy-MM-dd\n" ++
    "- 时间格式统一使用：yyyy-MM-dd HH:mm\n" ++
    "\n" ++
    "请用中文回复，保持专业友好。回复要简洁明了。";

pub const DEFAULT_SYSTEM_PROMPT =
    "你是一个AI驱动的助手，帮助用户完成各种任务。\n" ++
    "请用中文回复，保持专业友好。回复要简洁明了。";
