const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemNotifyMessages", handler.list);
    try app.get("/systemNotifyMessages/{id}", handler.show);
    try app.post("/systemNotifyMessages", handler.create);
    try app.put("/systemNotifyMessages/{id}", handler.update);
    try app.patch("/systemNotifyMessages/{id}", handler.patch);
    try app.delete("/systemNotifyMessages/{id}", handler.delete);
}
