const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemOauth2Approves", handler.list);
    try app.get("/systemOauth2Approves/{id}", handler.show);
    try app.post("/systemOauth2Approves", handler.create);
    try app.put("/systemOauth2Approves/{id}", handler.update);
    try app.patch("/systemOauth2Approves/{id}", handler.patch);
    try app.delete("/systemOauth2Approves/{id}", handler.delete);
}
