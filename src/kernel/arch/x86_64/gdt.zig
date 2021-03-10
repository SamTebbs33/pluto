const std = @import("std");
const log = std.log.scoped(.x86_64_gdt);

///
/// Initialise the Global Descriptor table.
///
pub fn init() void {
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});
}
