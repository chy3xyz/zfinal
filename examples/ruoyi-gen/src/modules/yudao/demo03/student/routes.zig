const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/yudaoDemo03Students", handler.list);
    try app.get("/yudaoDemo03Students/{id}", handler.show);
    try app.post("/yudaoDemo03Students", handler.create);
    try app.put("/yudaoDemo03Students/{id}", handler.update);
    try app.patch("/yudaoDemo03Students/{id}", handler.patch);
    try app.delete("/yudaoDemo03Students/{id}", handler.delete);
}
