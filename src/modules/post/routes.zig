try app.get("/posts", PostsController.list);
try app.get("/posts/:id", PostsController.show);
try app.post("/posts", PostsController.create);
try app.put("/posts/:id", PostsController.update);
try app.delete("/posts/:id", PostsController.delete);
