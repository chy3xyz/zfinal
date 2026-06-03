const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemMenus", handler.list);
    try app.get("/systemMenus/{id}", handler.show);
    try app.post("/systemMenus", handler.create);
    try app.put("/systemMenus/{id}", handler.update);
    try app.patch("/systemMenus/{id}", handler.patch);
    try app.delete("/systemMenus/{id}", handler.delete);
}
