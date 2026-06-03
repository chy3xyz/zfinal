const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/infraConfigs", handler.list);
    try app.get("/infraConfigs/{id}", handler.show);
    try app.post("/infraConfigs", handler.create);
    try app.put("/infraConfigs/{id}", handler.update);
    try app.patch("/infraConfigs/{id}", handler.patch);
    try app.delete("/infraConfigs/{id}", handler.delete);
}
