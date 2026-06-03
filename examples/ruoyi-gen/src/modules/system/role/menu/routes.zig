const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemRoleMenus", handler.list);
    try app.get("/systemRoleMenus/{id}", handler.show);
    try app.post("/systemRoleMenus", handler.create);
    try app.put("/systemRoleMenus/{id}", handler.update);
    try app.patch("/systemRoleMenus/{id}", handler.patch);
    try app.delete("/systemRoleMenus/{id}", handler.delete);
}
