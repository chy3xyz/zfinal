//! Structured security/ops audit events (auth fail, rate limit, CSRF).

const std = @import("std");
const getLogger = @import("logger.zig").getLogger;

pub const Event = enum {
    auth_fail,
    rate_limited,
    csrf_reject,
    jwt_ok,
};

/// Emit a one-line structured audit record via the global logger.
pub fn log(event: Event, path: []const u8, detail: []const u8) void {
    const name: []const u8 = switch (event) {
        .auth_fail => "auth_fail",
        .rate_limited => "rate_limited",
        .csrf_reject => "csrf_reject",
        .jwt_ok => "jwt_ok",
    };
    getLogger().warnFmt("audit event={s} path={s} detail={s}", .{ name, path, detail });
}
