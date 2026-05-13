try app.get("/users", UsersController.list);
try app.get("/users/:id", UsersController.show);
try app.post("/users", UsersController.create);
try app.put("/users/:id", UsersController.update);
try app.patch("/users/:id", UsersController.patch);
try app.delete("/users/:id", UsersController.delete);
