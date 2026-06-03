const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemPosts", handler.list);
    try app.get("/systemPosts/{id}", handler.show);
    try app.post("/systemPosts", handler.create);
    try app.put("/systemPosts/{id}", handler.update);
    try app.patch("/systemPosts/{id}", handler.patch);
    try app.delete("/systemPosts/{id}", handler.delete);
}
