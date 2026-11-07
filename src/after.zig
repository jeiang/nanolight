//! Later, on the UI thread: nanoui's `App.after`, typed. `oneShot` runs a
//! function on its context once; `Debounce` runs it once calls to `poke`
//! pause. `cast` is the one `*anyopaque` to typed pointer cast the
//! callbacks need.
const nanoui = @import("nanoui");

/// `ctx` back as the pointer type it was handed in as.
pub fn cast(comptime P: type, ctx: ?*anyopaque) P {
    return @ptrCast(@alignCast(ctx.?));
}

/// `func(ctx)` once, `ms` from now (0: once the current event is done).
pub fn oneShot(ms: u64, ctx: anytype, comptime func: fn (@TypeOf(ctx)) void) void {
    const P = @TypeOf(ctx);
    nanoui.App.after(ms, ctx, struct {
        fn fire(c: ?*anyopaque) callconv(.c) void {
            func(cast(P, c));
        }
    }.fire);
}

/// One run once `poke`s pause: each starts a wait of its own, and only the
/// last one to end runs. Kept in its owner, as the field `poke` names.
pub const Debounce = struct {
    pending: u32 = 0,

    pub fn waiting(d: *const Debounce) bool {
        return d.pending > 0;
    }

    /// `func` on the owner, whose `field` is `d`, once `ms` pass with no
    /// other `poke`.
    pub fn poke(
        d: *Debounce,
        ms: u64,
        comptime Owner: type,
        comptime field: []const u8,
        comptime func: fn (*Owner) void,
    ) void {
        d.pending += 1;
        oneShot(ms, d, struct {
            fn ended(it: *Debounce) void {
                it.pending -= 1;
                if (it.pending == 0) func(@alignCast(@fieldParentPtr(field, it)));
            }
        }.ended);
    }
};
