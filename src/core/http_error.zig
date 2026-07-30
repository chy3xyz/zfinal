//! Typed HTTP failures for handlers/extractors (Axum-style error mapping).
//! Prefer `return error.NotFound` (etc.) and let `Server.dispatch` render JSON.
const std = @import("std");
const Context = @import("context.zig").Context;

/// Stable error set mapped to HTTP status by `statusOf` / `render`.
pub const HttpError = error{
    BadRequest,
    Unauthorized,
    Forbidden,
    NotFound,
    MethodNotAllowed,
    Conflict,
    UnprocessableEntity,
    TooManyRequests,
    RequestTimeout,
    InternalServerError,
};

/// Optional human/machine detail set by extractors before returning an HttpError.
/// Not owned — use static strings or arena/request-lifetime slices.
pub fn setDetail(ctx: *Context, detail: []const u8) void {
    ctx.err_detail = detail;
}

pub fn clearDetail(ctx: *Context) void {
    ctx.err_detail = null;
}

pub fn statusOf(err: anyerror) ?std.http.Status {
    return switch (err) {
        error.BadRequest => .bad_request,
        error.Unauthorized => .unauthorized,
        error.Forbidden => .forbidden,
        error.NotFound => .not_found,
        error.MethodNotAllowed => .method_not_allowed,
        error.Conflict => .conflict,
        error.UnprocessableEntity => .unprocessable_entity,
        error.TooManyRequests => .too_many_requests,
        error.RequestTimeout => .request_timeout,
        error.InternalServerError => .internal_server_error,
        else => null,
    };
}

pub fn codeOf(err: anyerror) []const u8 {
    return switch (err) {
        error.BadRequest => "bad_request",
        error.Unauthorized => "unauthorized",
        error.Forbidden => "forbidden",
        error.NotFound => "not_found",
        error.MethodNotAllowed => "method_not_allowed",
        error.Conflict => "conflict",
        error.UnprocessableEntity => "unprocessable_entity",
        error.TooManyRequests => "too_many_requests",
        error.RequestTimeout => "request_timeout",
        error.InternalServerError => "internal_error",
        else => "internal_error",
    };
}

pub fn defaultMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.BadRequest => "Bad Request",
        error.Unauthorized => "Unauthorized",
        error.Forbidden => "Forbidden",
        error.NotFound => "Not Found",
        error.MethodNotAllowed => "Method Not Allowed",
        error.Conflict => "Conflict",
        error.UnprocessableEntity => "Unprocessable Entity",
        error.TooManyRequests => "Too Many Requests",
        error.RequestTimeout => "Request Timeout",
        error.InternalServerError => "Internal Server Error",
        else => "Internal Server Error",
    };
}

pub fn isHttpError(err: anyerror) bool {
    return statusOf(err) != null;
}

/// Render `{ "err": "<code>", "msg": "<message>", "detail": ? }` JSON.
pub fn render(ctx: *Context, err: anyerror) !void {
    if (ctx.response_started) return;
    const status = statusOf(err) orelse .internal_server_error;
    ctx.res_status = status;
    const code = codeOf(err);
    const msg = if (ctx.err_detail) |d| d else defaultMessage(err);
    if (ctx.err_detail != null) {
        try ctx.renderJson(.{ .err = code, .msg = defaultMessage(err), .detail = msg });
    } else {
        try ctx.renderJson(.{ .err = code, .msg = msg });
    }
    clearDetail(ctx);
}

/// Render with an explicit status/code/message (404/405 router path).
pub fn renderStatus(ctx: *Context, status: std.http.Status, code: []const u8, msg: []const u8) !void {
    if (ctx.response_started) return;
    ctx.res_status = status;
    try ctx.renderJson(.{ .err = code, .msg = msg });
}

test "statusOf maps HttpError" {
    try std.testing.expectEqual(std.http.Status.not_found, statusOf(error.NotFound).?);
    try std.testing.expect(statusOf(error.OutOfMemory) == null);
}
