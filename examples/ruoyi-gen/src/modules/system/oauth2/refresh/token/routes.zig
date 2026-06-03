const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemOauth2RefreshTokens", handler.list);
    try app.get("/systemOauth2RefreshTokens/{id}", handler.show);
    try app.post("/systemOauth2RefreshTokens", handler.create);
    try app.put("/systemOauth2RefreshTokens/{id}", handler.update);
    try app.patch("/systemOauth2RefreshTokens/{id}", handler.patch);
    try app.delete("/systemOauth2RefreshTokens/{id}", handler.delete);
}
