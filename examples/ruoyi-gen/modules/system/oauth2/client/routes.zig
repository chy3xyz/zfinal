const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemOauth2Clients", handler.list);
    try app.get("/systemOauth2Clients/{id}", handler.show);
    try app.post("/systemOauth2Clients", handler.create);
    try app.put("/systemOauth2Clients/{id}", handler.update);
    try app.patch("/systemOauth2Clients/{id}", handler.patch);
    try app.delete("/systemOauth2Clients/{id}", handler.delete);
}
