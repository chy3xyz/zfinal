const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemTenantPackages", handler.list);
    try app.get("/systemTenantPackages/{id}", handler.show);
    try app.post("/systemTenantPackages", handler.create);
    try app.put("/systemTenantPackages/{id}", handler.update);
    try app.patch("/systemTenantPackages/{id}", handler.patch);
    try app.delete("/systemTenantPackages/{id}", handler.delete);
}
