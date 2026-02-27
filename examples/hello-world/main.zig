const std = @import("std");
const zfinal = @import("zfinal");

fn helloHandler(ctx: *zfinal.Context) !void {
    try ctx.renderText("Hello, ZFinal!");
}

fn jsonHandler(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .message = "Hello, JSON!", .status = "ok" });
}

// Test query parameter handling
fn userHandler(ctx: *zfinal.Context) !void {
    const name = try ctx.getParaDefault("name", "Guest");
    const age = try ctx.getParaToIntDefault("age", 0);
    const premium = try ctx.getParaToBooleanDefault("premium", false);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "User: {s}, Age: {d}, Premium: {}", .{ name, age, premium });

    try ctx.renderJson(.{
        .name = name,
        .age = age,
        .premium = premium,
        .message = msg,
    });
}

// Test type conversion with optional parameters
fn calcHandler(ctx: *zfinal.Context) !void {
    const a = try ctx.getParaToInt("a");
    const b = try ctx.getParaToInt("b");

    if (a == null or b == null) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .err = "Missing parameters 'a' or 'b'" });
        return;
    }

    const sum = a.? + b.?;
    const product = a.? * b.?;

    try ctx.renderJson(.{
        .a = a.?,
        .b = b.?,
        .sum = sum,
        .product = product,
    });
}

// Test cookie handling
fn cookieSetHandler(ctx: *zfinal.Context) !void {
    try ctx.setCookie("user_id", "12345", 3600); // 1 hour
    try ctx.setCookie("session_token", "abc-xyz", null);
    try ctx.renderJson(.{ .message = "Cookies set successfully" });
}

fn cookieGetHandler(ctx: *zfinal.Context) !void {
    const user_id = try ctx.getCookieDefault("user_id", "not_set");
    const token = try ctx.getCookieDefault("session_token", "not_set");

    try ctx.renderJson(.{
        .user_id = user_id,
        .session_token = token,
    });
}

// Test attributes
fn attrHandler(ctx: *zfinal.Context) !void {
    try ctx.setAttr("request_id", "REQ-001");
    try ctx.setAttr("user_name", "Alice");

    const req_id = ctx.getAttr("request_id");
    const user = ctx.getAttrDefault("user_name", "Guest");

    try ctx.renderJson(.{
        .request_id = req_id,
        .user_name = user,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();

    try app.addRoute("/hello", helloHandler);
    try app.addRoute("/json", jsonHandler);
    try app.addRoute("/user", userHandler);
    try app.addRoute("/calc", calcHandler);
    try app.addRoute("/cookie/set", cookieSetHandler);
    try app.addRoute("/cookie/get", cookieGetHandler);
    try app.addRoute("/attr", attrHandler);

    std.debug.print("ZFinal server starting...\n", .{});
    std.debug.print("Try these routes:\n", .{});
    std.debug.print("  /hello\n", .{});
    std.debug.print("  /json\n", .{});
    std.debug.print("  /user?name=John&age=25&premium=true\n", .{});
    std.debug.print("  /calc?a=10&b=5\n", .{});
    std.debug.print("  /cookie/set\n", .{});
    std.debug.print("  /cookie/get\n", .{});
    std.debug.print("  /attr\n", .{});

    try app.start();
}
