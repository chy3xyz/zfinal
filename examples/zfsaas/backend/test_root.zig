//! Test root — package path is examples/saas-kit/ so schema.sql embeds cleanly.
test {
    _ = @import("src/password.zig");
    _ = @import("src/saas_kit_test.zig");
}
