const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemOperateLogs", handler.list);
    try app.get("/systemOperateLogs/{id}", handler.show);
    try app.post("/systemOperateLogs", handler.create);
    try app.put("/systemOperateLogs/{id}", handler.update);
    try app.patch("/systemOperateLogs/{id}", handler.patch);
    try app.delete("/systemOperateLogs/{id}", handler.delete);
}
