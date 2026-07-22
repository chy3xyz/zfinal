//! Shop + social domain schema (zent Schema-as-code).
//!
//!   User ──O2M──► Post
//!   User ── follow (via Follow rows) ──► User
//!   Product (catalog)
//!
//! Edges kept simple (FK fields) so migrate/CRUD stay reliable across zent 0.12.

const zent = @import("zfinal").zent;
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

pub const User = Schema("User", .{
    .fields = &.{
        field.String("name"),
        field.String("handle"),
    },
    .indexes = &.{
        zent.core.index.Fields(&.{"handle"}),
    },
});

pub const Product = Schema("Product", .{
    .fields = &.{
        field.Int("seller_id"),
        field.String("name"),
        field.Int("price_cents"),
        field.Int("stock").Default("0"),
    },
});

/// follower_id follows followee_id (social graph edge as row).
pub const Follow = Schema("Follow", .{
    .fields = &.{
        field.Int("follower_id"),
        field.Int("followee_id"),
    },
});

pub const Post = Schema("Post", .{
    .fields = &.{
        field.Int("author_id"),
        field.String("body"),
    },
});
