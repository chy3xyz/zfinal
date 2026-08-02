//! Async bus port — alias of framework `zfinal.Bus` (Memory / NATS / RobustMQ).
//! See `doc/bus.md`. App-local copy kept so services can `@import("../ports/bus.zig")`.
pub const Bus = @import("zfinal").Bus;
