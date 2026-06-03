const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemSmsCodes", handler.list);
    try app.get("/systemSmsCodes/{id}", handler.show);
    try app.post("/systemSmsCodes", handler.create);
    try app.put("/systemSmsCodes/{id}", handler.update);
    try app.patch("/systemSmsCodes/{id}", handler.patch);
    try app.delete("/systemSmsCodes/{id}", handler.delete);
}
