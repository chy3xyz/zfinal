const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/yudaoDemo01Contacts", handler.list);
    try app.get("/yudaoDemo01Contacts/{id}", handler.show);
    try app.post("/yudaoDemo01Contacts", handler.create);
    try app.put("/yudaoDemo01Contacts/{id}", handler.update);
    try app.patch("/yudaoDemo01Contacts/{id}", handler.patch);
    try app.delete("/yudaoDemo01Contacts/{id}", handler.delete);
}
