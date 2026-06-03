const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/yudaoDemo03Grades", handler.list);
    try app.get("/yudaoDemo03Grades/{id}", handler.show);
    try app.post("/yudaoDemo03Grades", handler.create);
    try app.put("/yudaoDemo03Grades/{id}", handler.update);
    try app.patch("/yudaoDemo03Grades/{id}", handler.patch);
    try app.delete("/yudaoDemo03Grades/{id}", handler.delete);
}
