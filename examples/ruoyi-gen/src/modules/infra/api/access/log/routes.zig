const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/infraApiAccessLogs", handler.list);
    try app.get("/infraApiAccessLogs/{id}", handler.show);
    try app.post("/infraApiAccessLogs", handler.create);
    try app.put("/infraApiAccessLogs/{id}", handler.update);
    try app.patch("/infraApiAccessLogs/{id}", handler.patch);
    try app.delete("/infraApiAccessLogs/{id}", handler.delete);
}
