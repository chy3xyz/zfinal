const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemDictTypes", handler.list);
    try app.get("/systemDictTypes/{id}", handler.show);
    try app.post("/systemDictTypes", handler.create);
    try app.put("/systemDictTypes/{id}", handler.update);
    try app.patch("/systemDictTypes/{id}", handler.patch);
    try app.delete("/systemDictTypes/{id}", handler.delete);
}
