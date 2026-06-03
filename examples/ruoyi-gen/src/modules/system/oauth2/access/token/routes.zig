const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemOauth2AccessTokens", handler.list);
    try app.get("/systemOauth2AccessTokens/{id}", handler.show);
    try app.post("/systemOauth2AccessTokens", handler.create);
    try app.put("/systemOauth2AccessTokens/{id}", handler.update);
    try app.patch("/systemOauth2AccessTokens/{id}", handler.patch);
    try app.delete("/systemOauth2AccessTokens/{id}", handler.delete);
}
