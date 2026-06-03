const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemMailAccounts", handler.list);
    try app.get("/systemMailAccounts/{id}", handler.show);
    try app.post("/systemMailAccounts", handler.create);
    try app.put("/systemMailAccounts/{id}", handler.update);
    try app.patch("/systemMailAccounts/{id}", handler.patch);
    try app.delete("/systemMailAccounts/{id}", handler.delete);
}
