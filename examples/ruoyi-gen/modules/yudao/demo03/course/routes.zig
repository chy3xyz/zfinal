const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/yudaoDemo03Courses", handler.list);
    try app.get("/yudaoDemo03Courses/{id}", handler.show);
    try app.post("/yudaoDemo03Courses", handler.create);
    try app.put("/yudaoDemo03Courses/{id}", handler.update);
    try app.patch("/yudaoDemo03Courses/{id}", handler.patch);
    try app.delete("/yudaoDemo03Courses/{id}", handler.delete);
}
