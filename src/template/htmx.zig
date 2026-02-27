const std = @import("std");
const Context = @import("../core/context.zig").Context;

/// HTMX 辅助函数
pub const HtmxHelper = struct {
    /// 生成 HTMX 属性
    pub fn hxGet(url: []const u8) []const u8 {
        return std.fmt.allocPrint(std.heap.page_allocator, "hx-get=\"{s}\"", .{url}) catch "";
    }

    pub fn hxPost(url: []const u8) []const u8 {
        return std.fmt.allocPrint(std.heap.page_allocator, "hx-post=\"{s}\"", .{url}) catch "";
    }

    pub fn hxTarget(target: []const u8) []const u8 {
        return std.fmt.allocPrint(std.heap.page_allocator, "hx-target=\"{s}\"", .{target}) catch "";
    }

    pub fn hxSwap(swap: []const u8) []const u8 {
        return std.fmt.allocPrint(std.heap.page_allocator, "hx-swap=\"{s}\"", .{swap}) catch "";
    }

    pub fn hxTrigger(trigger: []const u8) []const u8 {
        return std.fmt.allocPrint(std.heap.page_allocator, "hx-trigger=\"{s}\"", .{trigger}) catch "";
    }
};

/// Context 扩展：添加模板渲染方法
pub fn renderTemplate(ctx: *Context, template_name: []const u8, data: anytype) !void {
    // TODO: 集成 TemplateManager
    _ = ctx;
    _ = template_name;
    _ = data;
}
