const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemUserRoles", handler.list);
    try app.get("/systemUserRoles/{id}", handler.show);
    try app.post("/systemUserRoles", handler.create);
    try app.put("/systemUserRoles/{id}", handler.update);
    try app.patch("/systemUserRoles/{id}", handler.patch);
    try app.delete("/systemUserRoles/{id}", handler.delete);
}
