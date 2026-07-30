const handler = @import("handler.zig");

pub const module = .{
    .name = "assets",
    .prefix = "/assets",
};

pub const actions = .{
    .{ .name = "index", .method = .GET, .path = "", .handler = handler.index },
    .{ .name = "get", .method = .GET, .path = "/*path", .handler = handler.get },
};
