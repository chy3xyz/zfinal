const std = @import("std");

/// Wrapper to call pthread_mutex_init / pthread_mutex_destroy
/// via @cImport. The build system links libc anyway (linkSystemLibrary("c")
/// or link_libc = true in the module). zig translate-c handles pthread.h
/// and exposes pthread_mutex_init as an extern "c" function.
pub const pthread = struct {
    extern "c" fn pthread_mutex_init(
        mutex: *std.c.pthread_mutex_t,
        attr: ?*anyopaque,
    ) c_int;

    extern "c" fn pthread_mutex_destroy(
        mutex: *std.c.pthread_mutex_t,
    ) c_int;

    extern "c" fn pthread_cond_init(
        cond: *std.c.pthread_cond_t,
        attr: ?*anyopaque,
    ) c_int;

    extern "c" fn pthread_cond_destroy(
        cond: *std.c.pthread_cond_t,
    ) c_int;
};

/// Initialize a pthread_mutex_t via the runtime pthread_mutex_init
/// call, avoiding the value-copy hazard of PTHREAD_MUTEX_INITIALIZER
/// on aarch64-macos (64-byte struct with magic bytes that don't survive
/// struct copy).
pub fn initMutex(mutex: *std.c.pthread_mutex_t) !void {
    const rc = pthread.pthread_mutex_init(mutex, null);
    if (rc == 0) return;
    return error.MutexInit;
}

/// Destroy a mutex previously initialized with initMutex.
pub fn destroyMutex(mutex: *std.c.pthread_mutex_t) void {
    _ = pthread.pthread_mutex_destroy(mutex);
}

/// Initialize a pthread_cond_t — same rationale as initMutex.
pub fn initCond(cond: *std.c.pthread_cond_t) !void {
    const rc = pthread.pthread_cond_init(cond, null);
    if (rc == 0) return;
    return error.CondInit;
}

/// Destroy a condition variable.
pub fn destroyCond(cond: *std.c.pthread_cond_t) void {
    _ = pthread.pthread_cond_destroy(cond);
}
