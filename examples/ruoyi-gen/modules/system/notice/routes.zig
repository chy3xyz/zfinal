const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemNotices", handler.list);
    try app.get("/systemNotices/{id}", handler.show);
    try app.post("/systemNotices", handler.create);
    try app.put("/systemNotices/{id}", handler.update);
    try app.patch("/systemNotices/{id}", handler.patch);
    try app.delete("/systemNotices/{id}", handler.delete);
}
