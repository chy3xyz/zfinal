const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemSocialUserBinds", handler.list);
    try app.get("/systemSocialUserBinds/{id}", handler.show);
    try app.post("/systemSocialUserBinds", handler.create);
    try app.put("/systemSocialUserBinds/{id}", handler.update);
    try app.patch("/systemSocialUserBinds/{id}", handler.patch);
    try app.delete("/systemSocialUserBinds/{id}", handler.delete);
}
