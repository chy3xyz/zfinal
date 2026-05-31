const std = @import("std");
const io_instance = @import("../io_instance.zig");

fn getIo() std.Io {
    return io_instance.io;
}

/// A fixed-size thread pool for request handling.
/// Workers block on a condition variable when idle (no busy-spin).
pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    queue: TaskQueue,
    running: bool,
    max_concurrent: usize,
    active_count: std.atomic.Value(usize),

    const Task = struct {
        func: *const fn (*anyopaque) void,
        context: *anyopaque,
    };

    const TaskQueue = struct {
        mutex: std.Io.Mutex,
        cond: std.Io.Condition,
        items: std.ArrayList(Task),
        allocator: std.mem.Allocator,
        shutting_down: bool = false,

        pub fn init(allocator: std.mem.Allocator) TaskQueue {
            return .{
                .mutex = std.Io.Mutex.init,
                .cond = std.Io.Condition.init,
                .items = std.ArrayList(Task).empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *TaskQueue) void {
            self.items.deinit(self.allocator);
        }

        pub fn push(self: *TaskQueue, task: Task) !void {
            try self.mutex.lock(getIo());
            defer self.mutex.unlock(getIo());
            try self.items.append(self.allocator, task);
            self.cond.signal(getIo());
        }

        /// Blocking pop. Waits on condition variable when queue is empty.
        /// Returns null when shutting down.
        pub fn pop(self: *TaskQueue) ?Task {
            self.mutex.lock(getIo()) catch @panic("thread_pool: mutex lock failed");
            defer self.mutex.unlock(getIo());

            while (self.items.items.len == 0 and !self.shutting_down) {
                self.cond.waitUncancelable(getIo(), &self.mutex);
            }

            if (self.shutting_down and self.items.items.len == 0) return null;
            return self.items.pop();
        }

        pub fn signalShutdown(self: *TaskQueue) void {
            self.mutex.lock(getIo()) catch @panic("thread_pool: mutex lock failed");
            defer self.mutex.unlock(getIo());
            self.shutting_down = true;
            self.cond.broadcast(getIo());
        }
    };

    pub fn init(allocator: std.mem.Allocator, thread_count: usize, max_concurrent: usize) !ThreadPool {
        var pool = ThreadPool{
            .allocator = allocator,
            .threads = try allocator.alloc(std.Thread, thread_count),
            .queue = TaskQueue.init(allocator),
            .running = true,
            .max_concurrent = max_concurrent,
            .active_count = std.atomic.Value(usize).init(0),
        };

        for (0..thread_count) |i| {
            pool.threads[i] = try std.Thread.spawn(.{}, workerLoop, .{ &pool, i });
        }

        return pool;
    }

    pub fn deinit(self: *ThreadPool) void {
        // Signal shutdown to all waiting threads
        self.queue.signalShutdown();

        // Join all threads
        for (self.threads) |thread| {
            thread.join();
        }

        self.allocator.free(self.threads);
        self.queue.deinit();
    }

    pub fn submit(self: *ThreadPool, comptime Func: type, context: *anyopaque) !void {
        const current = self.active_count.load(.monotonic);
        if (current >= self.max_concurrent) {
            return error.TooManyRequests;
        }

        const wrapper = struct {
            fn call(ctx: *anyopaque) void {
                const typed_ctx: *Func = @ptrCast(@alignCast(ctx));
                typed_ctx.run();
            }
        }.call;

        try self.queue.push(.{
            .func = wrapper,
            .context = context,
        });
    }

    pub fn submitRaw(self: *ThreadPool, func: *const fn (*anyopaque) void, context: *anyopaque) !void {
        const current = self.active_count.load(.monotonic);
        if (current >= self.max_concurrent) {
            return error.TooManyRequests;
        }

        try self.queue.push(.{
            .func = func,
            .context = context,
        });
    }

    fn workerLoop(self: *ThreadPool, worker_id: usize) void {
        _ = worker_id;
        while (true) {
            // Blocking pop — waits on condition variable, zero CPU when idle.
            const task = self.queue.pop() orelse break;

            _ = self.active_count.fetchAdd(1, .monotonic);
            task.func(task.context);
            _ = self.active_count.fetchSub(1, .monotonic);
        }
    }
};

test "thread pool basic" {
    // Skip: std.Io.Mutex with std.testing.io does not support cross-thread futex operations
    if (true) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var pool = try ThreadPool.init(allocator, 2, 100);
    defer pool.deinit();

    const Context = struct {
        counter: std.atomic.Value(usize),

        pub fn run(self: *@This()) void {
            _ = self.counter.fetchAdd(1, .monotonic);
        }
    };

    var ctx = Context{ .counter = std.atomic.Value(usize).init(0) };

    for (0..10) |_| {
        try pool.submit(Context, &ctx);
    }

    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(50), .real) catch {};

    try std.testing.expect(ctx.counter.load(.monotonic) >= 1);
}
