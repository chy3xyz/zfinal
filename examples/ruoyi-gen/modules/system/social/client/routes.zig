const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemSocialClients", handler.list);
    try app.get("/systemSocialClients/{id}", handler.show);
    try app.post("/systemSocialClients", handler.create);
    try app.put("/systemSocialClients/{id}", handler.update);
    try app.patch("/systemSocialClients/{id}", handler.patch);
    try app.delete("/systemSocialClients/{id}", handler.delete);
}
