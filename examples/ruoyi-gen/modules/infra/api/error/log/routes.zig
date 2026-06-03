const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/infraApiErrorLogs", handler.list);
    try app.get("/infraApiErrorLogs/{id}", handler.show);
    try app.post("/infraApiErrorLogs", handler.create);
    try app.put("/infraApiErrorLogs/{id}", handler.update);
    try app.patch("/infraApiErrorLogs/{id}", handler.patch);
    try app.delete("/infraApiErrorLogs/{id}", handler.delete);
}
