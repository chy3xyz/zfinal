const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/infraCodegenColumns", handler.list);
    try app.get("/infraCodegenColumns/{id}", handler.show);
    try app.post("/infraCodegenColumns", handler.create);
    try app.put("/infraCodegenColumns/{id}", handler.update);
    try app.patch("/infraCodegenColumns/{id}", handler.patch);
    try app.delete("/infraCodegenColumns/{id}", handler.delete);
}
