const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemUsers", handler.list);
    try app.get("/systemUsers/{id}", handler.show);
    try app.post("/systemUsers", handler.create);
    try app.put("/systemUsers/{id}", handler.update);
    try app.patch("/systemUsers/{id}", handler.patch);
    try app.delete("/systemUsers/{id}", handler.delete);
}
