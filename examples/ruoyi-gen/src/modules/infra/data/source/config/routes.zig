const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/infraDataSourceConfigs", handler.list);
    try app.get("/infraDataSourceConfigs/{id}", handler.show);
    try app.post("/infraDataSourceConfigs", handler.create);
    try app.put("/infraDataSourceConfigs/{id}", handler.update);
    try app.patch("/infraDataSourceConfigs/{id}", handler.patch);
    try app.delete("/infraDataSourceConfigs/{id}", handler.delete);
}
