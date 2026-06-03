const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemRoles", handler.list);
    try app.get("/systemRoles/{id}", handler.show);
    try app.post("/systemRoles", handler.create);
    try app.put("/systemRoles/{id}", handler.update);
    try app.patch("/systemRoles/{id}", handler.patch);
    try app.delete("/systemRoles/{id}", handler.delete);
}
