//! Smart routing example — see doc/smart_routing.md
//! Generate: from repo root
//!   zig-out/bin/zf routes --root examples/smart-routing/src/modules --json

const handler = @import("handler.zig");

pub const module = .{
    .name = "users",
    .prefix = "/users",
    .interceptors = .{ "auth", "access_log" },
};

pub const actions = .{
    .{ .name = "index", .handler = handler.index },
    .{ .name = "show", .handler = handler.show },
    .{ .name = "create", .handler = handler.create },
    .{ .name = "update", .handler = handler.update },
    .{ .name = "destroy", .handler = handler.destroy },
    .{ .name = "login", .method = .POST, .action_key = "/auth/login", .handler = handler.login },
};
