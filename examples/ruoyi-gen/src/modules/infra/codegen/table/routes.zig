const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/infraCodegenTables", handler.list);
    try app.get("/infraCodegenTables/{id}", handler.show);
    try app.post("/infraCodegenTables", handler.create);
    try app.put("/infraCodegenTables/{id}", handler.update);
    try app.patch("/infraCodegenTables/{id}", handler.patch);
    try app.delete("/infraCodegenTables/{id}", handler.delete);
}
