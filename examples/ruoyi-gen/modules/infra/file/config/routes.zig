const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/infraFileConfigs", handler.list);
    try app.get("/infraFileConfigs/{id}", handler.show);
    try app.post("/infraFileConfigs", handler.create);
    try app.put("/infraFileConfigs/{id}", handler.update);
    try app.patch("/infraFileConfigs/{id}", handler.patch);
    try app.delete("/infraFileConfigs/{id}", handler.delete);
}
