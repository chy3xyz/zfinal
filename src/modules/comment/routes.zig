try app.get("/comments", CommentsController.list);
try app.get("/comments/:id", CommentsController.show);
try app.post("/comments", CommentsController.create);
try app.put("/comments/:id", CommentsController.update);
try app.delete("/comments/:id", CommentsController.delete);
