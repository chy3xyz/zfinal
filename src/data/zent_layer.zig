//! Data-layer alternative to `zfinal.DB` / `Model`.
//!
//! ZFinal ships **two** persistence stacks. Pick a **primary** for the app
//! (or per module); never mix drivers inside one transaction.
//!
//! | Stack | When it is the right primary |
//! |-------|------------------------------|
//! | `DB` / `Model` + `zf crud:sql` | Flat CRUD, existing SQL, AI SQL→module pipeline |
//! | `zfinal.zent` | Dense graphs, privacy, hooks — e-commerce / social / RBAC |
//!
//! ```zig
//! // Primary = SQL
//! const DB = zfinal.DB;
//! const Model = zfinal.Model;
//!
//! // Primary = zent (same discoverability)
//! const zent = zfinal.zent;
//! const Schema = zent.core.schema.Schema;
//! ```
//!
//! Disable at build time: `zig build -Denable-zent=false`.

const build_opts = @import("build_options");

/// `true` when built with `-Denable-zent=true` (default).
pub const enabled: bool = if (@hasDecl(build_opts, "enable_zent")) build_opts.enable_zent else false;

/// Re-export of the [zent](https://github.com/chy3xyz/zent) package (ent-style ORM).
/// Empty stub when built with `-Denable-zent=false`.
pub const api = if (enabled) @import("zent") else struct {
    pub const disabled = true;
};
