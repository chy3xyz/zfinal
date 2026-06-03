const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemDepts", handler.list);
    try app.get("/systemDepts/{id}", handler.show);
    try app.post("/systemDepts", handler.create);
    try app.put("/systemDepts/{id}", handler.update);
    try app.patch("/systemDepts/{id}", handler.patch);
    try app.delete("/systemDepts/{id}", handler.delete);
}
