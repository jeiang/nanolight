//! This OS's parts, picked once: the Mac's own (panel_mac.zig, preview.zig,
//! clickthrough.zig, recorder.zig, single_mac.zig), or Windows' and Linux's
//! (panel_pc.zig, pc_stubs.zig, single_win.zig, single_unix.zig). The app
//! holds them; screens see only platform.zig's flags.
const builtin = @import("builtin");
const platform = @import("platform.zig");
const login = @import("login.zig");
const stubs = @import("pc_stubs.zig");
const os = builtin.os.tag;
const mac = @import("os.zig").mac;

/// The panel's window: adjust, setup, place, resize, shown, showing,
/// lostKeys, prepare.
pub const panel = if (mac) @import("panel_mac.zig") else @import("panel_pc.zig");
pub const Preview = if (platform.preview) @import("preview.zig").Preview else stubs.Preview;
/// Clicks round the panel reach what is under it: only the Mac's window
/// is bigger than the panel.
pub const ClickThrough = if (mac) @import("clickthrough.zig").ClickThrough else stubs.ClickThrough;
pub const Recorder = if (platform.record) @import("recorder.zig").Recorder else stubs.Recorder;
/// One copy at a time and commands from a second one (single.zig).
pub const Single = switch (os) {
    .macos => @import("single_mac.zig"),
    .windows => @import("single_win.zig"),
    else => @import("single_unix.zig"),
};
pub const Login = switch (os) {
    .macos => login.Mac,
    .windows => login.Windows,
    else => login.Linux,
};

// The stubs and the PC's panel stand in for the Mac's types: the same
// public declarations, of the same types. Checked where the Mac's can be
// analyzed (their fields are AppKit's), so drift fails the Mac's build.
comptime {
    if (mac) {
        conforms(@import("preview.zig").Preview, stubs.Preview);
        conforms(@import("clickthrough.zig").ClickThrough, stubs.ClickThrough);
        conforms(@import("recorder.zig").Recorder, stubs.Recorder);
        conforms(@import("panel_mac.zig"), @import("panel_pc.zig"));
    }
}

/// `Stand` declares what `Real` does, each of the same type (a method's
/// receiver its own), and only fields `Real` has.
fn conforms(comptime Real: type, comptime Stand: type) void {
    const real = @typeInfo(Real).@"struct";
    const stand = @typeInfo(Stand).@"struct";
    const who = @typeName(Stand) ++ " (for " ++ @typeName(Real) ++ ")";
    for (real.decl_names) |name| {
        if (!@hasDecl(Stand, name)) @compileError(who ++ " lacks " ++ name);
    }
    for (stand.decl_names) |name| {
        if (!@hasDecl(Real, name)) @compileError(who ++ " has " ++ name ++ ", which it lacks");
        const R = @TypeOf(@field(Real, name));
        const S = @TypeOf(@field(Stand, name));
        const same = if (R == type)
            S == type and @field(Real, name) == @field(Stand, name)
        else if (@typeInfo(R) == .@"fn" and @typeInfo(S) == .@"fn")
            sameFn(Real, Stand, @typeInfo(R).@"fn", @typeInfo(S).@"fn")
        else
            R == S;
        if (!same) @compileError(who ++ "." ++ name ++ " differs: " ++
            @typeName(S) ++ " for " ++ @typeName(R));
    }
    for (stand.field_names, stand.field_types) |name, T| {
        if (!@hasField(Real, name) or @FieldType(Real, name) != T)
            @compileError(who ++ "." ++ name ++ " is no field of the same type");
    }
}

fn sameFn(comptime Real: type, comptime Stand: type, r: anytype, s: anytype) bool {
    if (r.is_generic or s.is_generic) return false;
    if (r.param_types.len != s.param_types.len) return false;
    if (own(Real, Stand, r.return_type.?) != s.return_type.?) return false;
    for (r.param_types, s.param_types) |a, b| {
        if (own(Real, Stand, a.?) != b.?) return false;
    }
    return true;
}

/// `T`, with `Real` (a receiver) read as `Stand`.
fn own(comptime Real: type, comptime Stand: type, comptime T: type) type {
    if (T == Real) return Stand;
    if (T == *Real) return *Stand;
    if (T == *const Real) return *const Stand;
    return T;
}
