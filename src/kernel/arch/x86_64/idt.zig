const std = @import("std");
const log = std.log.scoped(.x86_64_idt);

///
/// Initialise the Interrupt descriptor table
///
pub fn init() void {
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});
}
