//! Which OS this build is for, named once.
const builtin = @import("builtin");

pub const mac = builtin.os.tag == .macos;
pub const windows = builtin.os.tag == .windows;
