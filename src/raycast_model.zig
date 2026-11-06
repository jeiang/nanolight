//! What a script command's screen (raycast_view.zig) shows, as its runner
//! (script_run.zig) builds it: the arguments' form or a detail (its output,
//! or a question). The runner drives the screen with `Update`s; the screen
//! tells the runner back with `Event`s.
const std = @import("std");

/// A script declares at most three arguments (`@raycast.argument1` to
/// `@raycast.argument3`), and its form has a field for each.
pub const max_args = 3;

pub const Action = enum {
    run,
    again,
    copy,

    pub fn title(a: Action) []const u8 {
        return switch (a) {
            .run => "Run",
            .again => "Run Again",
            .copy => "Copy Output",
        };
    }
};

/// A view's actions are in key order: Return runs the one at `return_at`,
/// ⌘↩ the one at `cmd_return_at` (a form's ⌘↩ submits it with its first, as
/// Raycast's does). The rest are only in the actions list.
pub const return_at = 0;
pub const cmd_return_at = 1;

pub const Option = struct {
    value: []const u8,
    title: []const u8,
};

/// One of the script's arguments.
pub const Field = struct {
    /// Which argument: 0 for `@raycast.argument1`.
    slot: usize,
    kind: Kind = .text,
    title: []const u8,
    placeholder: []const u8 = "",
    value: []const u8 = "",
    options: []const Option = &.{},

    /// A script's argument types; a password is typed but not shown.
    pub const Kind = enum { text, password, dropdown };
};

/// The arguments, asked for before a run.
pub const Form = struct {
    title: []const u8,
    fields: []const Field,
    actions: []const Action,
};

/// A script's output, or a question about it ("Run X?").
pub const Detail = struct {
    title: []const u8,
    body: Body,
    /// Still running: the header says "Loading…".
    loading: bool = false,
    actions: []const Action = &.{},

    pub const Body = union(enum) {
        /// A heading and lines, from Markdown (`plain`).
        markdown: []const u8,
        /// Lines as printed, monospaced.
        output: []const u8,
    };
};

pub const View = union(enum) {
    form: Form,
    detail: Detail,

    pub fn title(v: View) []const u8 {
        return switch (v) {
            inline else => |x| x.title,
        };
    }

    pub fn actions(v: View) []const Action {
        return switch (v) {
            inline else => |x| x.actions,
        };
    }
};

/// What the screen tells its runner.
pub const Event = union(enum) {
    action: Action,
    /// A field's new value, which lives until the runner returns.
    field: struct { slot: usize, value: []const u8 },
    /// Escape or the back button: the runner ends the script and stops
    /// the screen.
    pop,
};

/// Where the screen's events go. The runner answers within the call: a new
/// view, a note, or, on a pop, the screen stopped.
pub const Sender = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, event: Event) void,
};

/// The command's name and its icon (PNG), for the header and the footer.
/// The screen copies both: they may come from an index that is replaced
/// while it is up (script_live.zig `refresh`).
pub const Command = struct {
    name: []const u8,
    icon: ?[]const u8 = null,
};

/// What the runner tells its screen.
pub const Update = union(enum) {
    /// Opens the screen for a command, its events sent to `to`.
    start: struct { command: Command, to: Sender },
    /// The new top view; `arena` holds it and is now the screen's.
    show: struct { arena: std.heap.ArenaAllocator, view: View },
    /// Said in the footer for a while.
    note: struct { text: []const u8, bad: bool },
    stop,
};

/// Where the runner's updates go: the screen, which applies each within
/// the call.
pub const Screen = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, update: Update) void,
};

/// Markdown as plain lines for the panel: headings, emphasis and code
/// marks dropped, images left out, links as their words.
pub fn plain(buf: []u8, md: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    var line_start = true;
    while (i < md.len and n < buf.len) {
        const ch = md[i];
        if (line_start) {
            while (i < md.len and (md[i] == '#' or (md[i] == '>' and (i + 1 >= md.len or
                md[i + 1] == ' ')))) i += 1;
            while (i < md.len and md[i] == ' ' and n > 0 and buf[n - 1] == '\n') i += 1;
            line_start = false;
            continue;
        }
        if (ch == '!' and i + 1 < md.len and md[i + 1] == '[') {
            // ![alt](src): left out.
            const close = std.mem.indexOfScalarPos(u8, md, i, ')') orelse md.len - 1;
            i = close + 1;
            continue;
        }
        if (ch == '[') {
            // [words](href): the words.
            if (std.mem.indexOfScalarPos(u8, md, i, ']')) |rb| if (rb + 1 < md.len and
                md[rb + 1] == '(')
            {
                const words = md[i + 1 .. rb];
                const m = @min(words.len, buf.len - n);
                @memcpy(buf[n..][0..m], words[0..m]);
                n += m;
                i = (std.mem.indexOfScalarPos(u8, md, rb, ')') orelse md.len - 1) + 1;
                continue;
            };
        }
        if (ch == '*' or ch == '`' or (ch == '_' and (i + 1 < md.len and md[i + 1] == '_'))) {
            i += 1;
            continue;
        }
        buf[n] = ch;
        n += 1;
        if (ch == '\n') line_start = true;
        i += 1;
    }
    return std.mem.trim(u8, buf[0..n], " \n");
}

test "markdown reads as text" {
    var buf: [256]u8 = undefined;
    const md = "# Hello **world**\n![x](y.png)See [docs](https://a.b) and `code`.";
    try std.testing.expectEqualStrings("Hello world\nSee docs and code.", plain(&buf, md));
}
