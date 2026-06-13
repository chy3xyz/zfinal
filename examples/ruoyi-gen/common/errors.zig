// Unified error response shapes.

pub const ErrorCode = enum {
    bad_request,
    unauthorized,
    forbidden,
    not_found,
    conflict,
    too_many_requests,
    internal,
};

pub fn errorBody(comptime code: ErrorCode, msg: []const u8) type {
    return .{ .err = msg, .code = @tagName(code) };
}
