const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemLoginLogs", handler.list);
    try app.get("/systemLoginLogs/{id}", handler.show);
    try app.post("/systemLoginLogs", handler.create);
    try app.put("/systemLoginLogs/{id}", handler.update);
    try app.patch("/systemLoginLogs/{id}", handler.patch);
    try app.delete("/systemLoginLogs/{id}", handler.delete);
}
