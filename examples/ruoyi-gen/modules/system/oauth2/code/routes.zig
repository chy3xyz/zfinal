const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemOauth2Codes", handler.list);
    try app.get("/systemOauth2Codes/{id}", handler.show);
    try app.post("/systemOauth2Codes", handler.create);
    try app.put("/systemOauth2Codes/{id}", handler.update);
    try app.patch("/systemOauth2Codes/{id}", handler.patch);
    try app.delete("/systemOauth2Codes/{id}", handler.delete);
}
