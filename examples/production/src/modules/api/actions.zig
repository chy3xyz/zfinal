//! Smart routing true source — regenerate: zf routes --root examples/production/src/modules
const handler = @import("handler.zig");

pub const module = .{
    .name = "api",
    .prefix = "/api",
};

pub const actions = .{
    .{ .name = "form", .method = .GET, .action_key = "/api/form", .handler = handler.form },
    .{ .name = "submit", .method = .POST, .action_key = "/api/submit", .handler = handler.submit, .interceptors = .{"csrf"} },
    .{ .name = "me", .method = .GET, .action_key = "/api/me", .handler = handler.me, .interceptors = .{"jwt"} },
    .{ .name = "token", .method = .POST, .action_key = "/api/token", .handler = handler.issueToken },
};
