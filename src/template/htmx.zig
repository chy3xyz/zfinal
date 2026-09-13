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

/// Context 扩展：模板渲染入口。
///
/// ⚠️ 这是一个**未实现的占位**。原实现丢弃全部参数并静默返回成功，调用方会误以为
/// 渲染成功。经全仓 grep，`renderTemplate` 没有任何调用方（`src/template/htmx.zig`
/// 也未被任何文件 @import），因此改成 `@compileError`：未来的调用方会在**编译期**
/// 得到明确错误，而不是运行时静默 no-op。
///
/// 若要真正启用：接入 `src/template/template.zig` 的 `TemplateManager` 完成渲染，
/// 或删除该入口。
pub fn renderTemplate(ctx: *Context, template_name: []const u8, data: anytype) !void {
    _ = ctx;
    _ = template_name;
    _ = data;
    @compileError("HtmxHelper.renderTemplate is a stub: wire it to TemplateManager or remove this entry point");
}
