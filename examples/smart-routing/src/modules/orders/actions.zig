const handler = @import("handler.zig");

pub const module = .{
    .name = "orders",
    .prefix = "/orders",
    .nested_under = .{ .parent = "users", .param = "user_id" },
};

pub const actions = .{
    .{ .name = "index", .handler = handler.index },
    .{ .name = "show", .handler = handler.show },
    .{ .name = "create", .handler = handler.create },
};
