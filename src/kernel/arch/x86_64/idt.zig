const std = @import("std");
const log = std.log.scoped(.x86_64_idt);

/// The IDT pointer structure that contains the pointer to the beginning of the IDT and the number
/// of the table (minus 1). Used to load the IST with LIDT instruction.
pub const IdtPtr = packed struct {
    /// The total size of the IDT (minus 1) in bytes.
    limit: u16,

    /// The base address where the IDT is located.
    base: u64,
};

/// The function type for the interrupt handlers.
pub const InterruptHandler = fn () callconv(.Naked) void;

/// The error set for the IDT
pub const IdtError = error{
    /// A IDT entry already exists for the provided index.
    IdtEntryExists,
};

///
/// Initialise the Interrupt descriptor table
///
pub fn init() void {
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});
}
