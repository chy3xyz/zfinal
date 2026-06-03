const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemTenants", handler.list);
    try app.get("/systemTenants/{id}", handler.show);
    try app.post("/systemTenants", handler.create);
    try app.put("/systemTenants/{id}", handler.update);
    try app.patch("/systemTenants/{id}", handler.patch);
    try app.delete("/systemTenants/{id}", handler.delete);
}
