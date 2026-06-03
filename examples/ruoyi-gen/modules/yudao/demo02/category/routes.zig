const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/yudaoDemo02Categories", handler.list);
    try app.get("/yudaoDemo02Categories/{id}", handler.show);
    try app.post("/yudaoDemo02Categories", handler.create);
    try app.put("/yudaoDemo02Categories/{id}", handler.update);
    try app.patch("/yudaoDemo02Categories/{id}", handler.patch);
    try app.delete("/yudaoDemo02Categories/{id}", handler.delete);
}
