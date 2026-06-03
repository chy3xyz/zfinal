const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemSmsLogs", handler.list);
    try app.get("/systemSmsLogs/{id}", handler.show);
    try app.post("/systemSmsLogs", handler.create);
    try app.put("/systemSmsLogs/{id}", handler.update);
    try app.patch("/systemSmsLogs/{id}", handler.patch);
    try app.delete("/systemSmsLogs/{id}", handler.delete);
}
