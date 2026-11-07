//! The sync wire between a client (account.zig) and nanolight-server
//! (server_protocol.zig): a PUT of this machine's settings record
//! (settings.zig) to `path`, answered with the record merged with the
//! account's; a GET of `path` reads the account's record.
const std = @import("std");

pub const path = "/v1/sync";
/// Answers "ok" without a token.
pub const health_path = "/healthz";
pub const authorization_header = "Authorization";
/// What goes before the account's token in `authorization_header`.
pub const bearer_prefix = "Bearer ";
/// `first_header: first_value` marks a machine's first sync with a server:
/// the stored record wins. Header names match in any case.
pub const first_header = "X-Nanolight-First";
pub const first_value = "1";
/// Of requests and replies alike, in `content_type_header`.
pub const content_type = "application/json";
pub const content_type_header = "Content-Type";
/// Sends this machine's record; answered with the merge.
pub const method_put = "PUT";
/// Reads the account's record, and the health check.
pub const method_get = "GET";

/// A request body at most; a larger one is refused (413).
pub const max_body = 256 * 1024;
/// A stored record at most: room for a merge of two whole requests.
pub const max_stored = max_body * 2;

pub const account_max = 64;

/// An account name: `[a-z0-9_-]`, 1 to `account_max` of them, so it is safe
/// as a file name.
pub fn validAccount(name: []const u8) bool {
    if (name.len == 0 or name.len > account_max) return false;
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

test "an account name is short, lower case, and safe as a file name" {
    const longest: [account_max]u8 = @splat('a');
    try std.testing.expect(validAccount(&longest));
    try std.testing.expect(validAccount("a_b-1"));
    try std.testing.expect(!validAccount(longest ++ "a"));
    for ([_][]const u8{ "", "Alice", "al ice", "../x", "a.json" }) |name| {
        try std.testing.expect(!validAccount(name));
    }
}
