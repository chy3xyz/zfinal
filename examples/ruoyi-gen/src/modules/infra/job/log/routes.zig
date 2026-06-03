const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/infraJobLogs", handler.list);
    try app.get("/infraJobLogs/{id}", handler.show);
    try app.post("/infraJobLogs", handler.create);
    try app.put("/infraJobLogs/{id}", handler.update);
    try app.patch("/infraJobLogs/{id}", handler.patch);
    try app.delete("/infraJobLogs/{id}", handler.delete);
}
