// Todo routes under /api/todos (JWT + org scope).
const zfinal = @import("zfinal");
const handler = @import("handler.zig");

pub fn register(app: anytype, auth: []const zfinal.Interceptor) !void {
    try app.getWithInterceptors("/api/todos", handler.list, auth);
    try app.getWithInterceptors("/api/todos/:id", handler.show, auth);
    try app.postWithInterceptors("/api/todos", handler.create, auth);
    try app.putWithInterceptors("/api/todos/:id", handler.update, auth);
    try app.deleteWithInterceptors("/api/todos/:id", handler.delete, auth);
}
