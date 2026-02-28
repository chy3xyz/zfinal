const std = @import("std");
const zfinal = @import("zfinal");
const Token = @import("../auth/token.zig");
const State = @import("../state.zig");

/// Helper to get global DB
fn getDb() *zfinal.DB {
    return State.global_state.?.db;
}

/// Middleware to check API token authentication
pub fn checkApiToken(ctx: *zfinal.Context) !bool {
    const db = getDb();

    // Get Authorization header
    const auth_header = ctx.getHeader("Authorization");

    if (auth_header) |header| {
        // Check for "Bearer <token>" format
        if (std.mem.startsWith(u8, header, "Bearer ")) {
            const token = header[7..]; // Skip "Bearer "

            // Validate token
            const is_valid = try Token.validateToken(token, db, ctx.allocator);

            if (is_valid) {
                // Token valid, proceed to handler
                return true;
            }
        }
    }

    // No valid token, return 401
    ctx.res_status = .unauthorized;
    try ctx.renderJson(.{
        .@"error" = "Unauthorized",
        .message = "Invalid or missing API token",
        .hint = "Include 'Authorization: Bearer <token>' header",
    });
    return false;
}
