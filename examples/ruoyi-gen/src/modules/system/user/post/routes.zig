const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemUserPosts", handler.list);
    try app.get("/systemUserPosts/{id}", handler.show);
    try app.post("/systemUserPosts", handler.create);
    try app.put("/systemUserPosts/{id}", handler.update);
    try app.patch("/systemUserPosts/{id}", handler.patch);
    try app.delete("/systemUserPosts/{id}", handler.delete);
}
