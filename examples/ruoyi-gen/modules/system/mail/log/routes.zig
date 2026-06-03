const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemMailLogs", handler.list);
    try app.get("/systemMailLogs/{id}", handler.show);
    try app.post("/systemMailLogs", handler.create);
    try app.put("/systemMailLogs/{id}", handler.update);
    try app.patch("/systemMailLogs/{id}", handler.patch);
    try app.delete("/systemMailLogs/{id}", handler.delete);
}
