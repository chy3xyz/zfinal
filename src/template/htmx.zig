const std = @import("std");
const Context = @import("../core/context.zig").Context;

/// HTMX 辅助函数 — caller owns returned memory (must free with given allocator)
pub const HtmxHelper = struct {
    pub fn hxGet(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "hx-get=\"{s}\"", .{url});
    }

    pub fn hxPost(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "hx-post=\"{s}\"", .{url});
    }

    pub fn hxTarget(allocator: std.mem.Allocator, target: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "hx-target=\"{s}\"", .{target});
    }

    pub fn hxSwap(allocator: std.mem.Allocator, swap: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "hx-swap=\"{s}\"", .{swap});
    }

    pub fn hxTrigger(allocator: std.mem.Allocator, trigger: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "hx-trigger=\"{s}\"", .{trigger});
    }
};

/// Context 扩展：添加模板渲染方法
pub fn renderTemplate(ctx: *Context, template_name: []const u8, data: anytype) !void {
    // TODO: 集成 TemplateManager
    _ = ctx;
    _ = template_name;
    _ = data;
}
