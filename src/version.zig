//! Framework version — single source of truth for runtime + codegen manifests.
//! Must match `.version` in `build.zig.zon` (asserted in `build.zig`).

pub const semver = "0.20.9";
pub const tag = "v" ++ semver;
