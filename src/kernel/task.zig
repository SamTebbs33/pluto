const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const builtin = @import("builtin");
const is_test = builtin.is_test;
const build_options = @import("build_options");
const mock_path = build_options.mock_path;
const arch = @import("arch.zig").internals;
const panic = if (is_test) @import(mock_path ++ "panic_mock.zig").panic else @import("panic.zig").panic;
const ComptimeBitmap = @import("bitmap.zig").ComptimeBitmap;
const vmm = if (is_test) @import(mock_path ++ "vmm_mock.zig") else @import("vmm.zig");
const pmm = @import("pmm.zig");
const mem = if (is_test) @import(mock_path ++ "mem_mock.zig") else @import("mem.zig");
const elf = @import("elf.zig");
const bitmap = @import("bitmap.zig");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.task);

/// The kernels main stack start as this is used to check for if the task being destroyed is this stack
/// as we cannot deallocate this.
extern var KERNEL_STACK_START: *u32;

/// The function type for the entry point.
pub const EntryPoint = usize;

/// The bitmap type for the PIDs
const PidBitmap = if (is_test) ComptimeBitmap(u128) else ComptimeBitmap(u1024);

/// The list of PIDs that have been allocated.
var all_pids: PidBitmap = brk: {
    var pids = PidBitmap.init();
    // Set the first PID as this is for the current task running, init 0
    _ = pids.setFirstFree() orelse unreachable;
    break :brk pids;
};

/// The default stack size of a task. Currently this is set to a page size.
pub const STACK_SIZE: u32 = arch.MEMORY_BLOCK_SIZE / @sizeOf(u32);

/// The task control block for storing all the information needed to save and restore a task.
pub const Task = struct {
    const Self = @This();

    /// The unique task identifier
    pid: PidBitmap.IndexType,

    /// Pointer to the kernel stack for the task. This will be allocated on initialisation.
    kernel_stack: []usize,

    /// Pointer to the user stack for the task. This will be allocated on initialisation and will be empty if it's a kernel task
    user_stack: []usize,

    /// The current stack pointer into the stack.
    stack_pointer: usize,

    /// Whether the process is a kernel process or not
    kernel: bool,

    /// The virtual memory manager belonging to the task
    vmm: *vmm.VirtualMemoryManager(arch.VmmPayload),

    ///
    /// Create a task. This will allocate a PID and the stack. The stack will be set up as a
    /// kernel task. As this is a new task, the stack will need to be initialised with the CPU
    /// state as described in arch.CpuState struct.
    ///
    /// Arguments:
    ///     IN entry_point: EntryPoint - The entry point into the task. This must be a function.
    ///     IN kernel: bool              - Whether the task has kernel or user privileges.
    ///     IN task_vmm: *VirtualMemoryManager - The virtual memory manager associated with the task.
    ///     IN allocator: *Allocator     - The allocator for allocating memory for a task.
    ///
    /// Return: *Task
    ///     Pointer to an allocated task. This will then need to be added to the task queue.
    ///
    /// Error: Allocator.Error
    ///     OutOfMemory - If there is no more memory to allocate. Any memory or PID allocated will
    ///                   be freed on return.
    ///
    pub fn create(entry_point: EntryPoint, kernel: bool, task_vmm: *vmm.VirtualMemoryManager(arch.VmmPayload), allocator: *Allocator) Allocator.Error!*Task {
        var task = try allocator.create(Task);
        errdefer allocator.destroy(task);

        const pid = allocatePid();
        errdefer freePid(pid);

        var k_stack = try allocator.alloc(usize, STACK_SIZE);
        errdefer allocator.free(k_stack);

        var u_stack = if (kernel) &[_]usize{} else try allocator.alloc(usize, STACK_SIZE);
        errdefer if (!kernel) allocator.free(u_stack);

        task.* = .{
            .pid = pid,
            .kernel_stack = k_stack,
            .user_stack = u_stack,
            .stack_pointer = @ptrToInt(&k_stack[STACK_SIZE - 1]),
            .kernel = kernel,
            .vmm = task_vmm,
        };

        try arch.initTask(task, entry_point, allocator);

        return task;
    }

    pub fn createFromElf(program_elf: elf.Elf, kernel: bool, task_vmm: *vmm.VirtualMemoryManager(arch.VmmPayload), allocator: *Allocator) (bitmap.Bitmap(usize).BitmapError || vmm.VmmError || elf.Error || Allocator.Error)!*Task {
        const task = try create(program_elf.header.entry_address, kernel, task_vmm, allocator);
        errdefer task.destroy(allocator);

        // Iterate over sections
        for (program_elf.section_headers) |header, i| {
            log.debug("Section {}\n", .{header.getName(program_elf)});
            if ((header.flags & elf.SECTION_ALLOCATABLE) == 0) {
                continue;
            }
            // If it is loadable then allocate it at its virtual address
            const attrs = vmm.Attributes{ .kernel = kernel, .writable = (header.flags & elf.SECTION_WRITABLE) != 0, .cachable = true };
            log.debug("Allocating {} section with address {X} and attributes {}\n", .{ header.getName(program_elf), header.virtual_address, attrs });
            const vaddr = (try task_vmm.alloc(std.mem.alignForward(header.size, vmm.BLOCK_SIZE) / vmm.BLOCK_SIZE, header.virtual_address, attrs)) orelse return if (try task_vmm.isSet(header.virtual_address)) error.AlreadyAllocated else error.OutOfBounds;
            errdefer task_vmm.free(vaddr) catch |e| panic(@errorReturnTrace(), "Failed to free VMM memory in createFromElf: {}\n", .{e});
            // Copy it into memory
            try vmm.kernel_vmm.copyData(task_vmm, true, program_elf.section_data[i].?, vaddr);
        }
        log.debug("Created task with entry point {X}\n", .{program_elf.header.entry_address});
        return task;
    }

    ///
    /// Destroy the task. This will release the allocated PID and free the stack and self.
    ///
    /// Arguments:
    ///     IN/OUT self: *Self - The pointer to self.
    ///
    pub fn destroy(self: *Self, allocator: *Allocator) void {
        freePid(self.pid);
        // We need to check that the the stack has been allocated as task 0 (init) won't have a
        // stack allocated as this in the linker script
        if (@ptrToInt(self.kernel_stack.ptr) != @ptrToInt(&KERNEL_STACK_START)) {
            allocator.free(self.kernel_stack);
        }
        if (!self.kernel) {
            allocator.free(self.user_stack);
        }
        allocator.destroy(self);
    }
};

///
/// Allocate a process identifier. If out of PIDs, then will panic. Is this occurs, will need to
/// increase the bitmap.
///
/// Return: u32
///     A new PID.
///
fn allocatePid() PidBitmap.IndexType {
    return all_pids.setFirstFree() orelse panic(@errorReturnTrace(), "Out of PIDs\n", .{});
}

///
/// Free an allocated PID. One must be allocated to be freed. If one wasn't allocated will panic.
///
/// Arguments:
///     IN pid: u32 - The PID to free.
///
fn freePid(pid: PidBitmap.IndexType) void {
    if (!all_pids.isSet(pid)) {
        panic(@errorReturnTrace(), "PID {} not allocated\n", .{pid});
    }
    all_pids.clearEntry(pid);
}

// For testing the errdefer
const FailingAllocator = std.testing.FailingAllocator;
const testing_allocator = &std.testing.base_allocator_instance.allocator;

fn test_fn1() void {}

test "create out of memory for task" {
    // Set the global allocator
    var fa = FailingAllocator.init(testing_allocator, 0);

    expectError(error.OutOfMemory, Task.create(@ptrToInt(test_fn1), true, undefined, &fa.allocator));
    expectError(error.OutOfMemory, Task.create(@ptrToInt(test_fn1), false, undefined, &fa.allocator));

    // Make sure any memory allocated is freed
    expectEqual(fa.allocated_bytes, fa.freed_bytes);

    // Make sure no PIDs were allocated
    expectEqual(all_pids.bitmap, 1);
}

test "create out of memory for stack" {
    // Set the global allocator
    var fa = FailingAllocator.init(testing_allocator, 1);

    expectError(error.OutOfMemory, Task.create(@ptrToInt(test_fn1), true, undefined, &fa.allocator));
    expectError(error.OutOfMemory, Task.create(@ptrToInt(test_fn1), false, undefined, &fa.allocator));

    // Make sure any memory allocated is freed
    expectEqual(fa.allocated_bytes, fa.freed_bytes);

    // Make sure no PIDs were allocated
    expectEqual(all_pids.bitmap, 1);
}

test "create expected setup" {
    var task = try Task.create(@ptrToInt(test_fn1), true, undefined, std.testing.allocator);
    defer task.destroy(std.testing.allocator);

    // Will allocate the first PID 1, 0 will always be allocated
    expectEqual(task.pid, 1);
    expectEqual(task.kernel_stack.len, STACK_SIZE);
    expectEqual(task.user_stack.len, 0);

    var user_task = try Task.create(@ptrToInt(test_fn1), false, undefined, std.testing.allocator);
    defer user_task.destroy(std.testing.allocator);
    expectEqual(user_task.pid, 2);
    expectEqual(user_task.user_stack.len, STACK_SIZE);
    expectEqual(user_task.kernel_stack.len, STACK_SIZE);
}

test "destroy cleans up" {
    // This used the leak detector allocator in testing
    // So if any alloc were not freed, this will fail the test
    var allocator = std.testing.allocator;

    var task = try Task.create(@ptrToInt(test_fn1), true, undefined, allocator);
    var user_task = try Task.create(@ptrToInt(test_fn1), false, undefined, allocator);

    task.destroy(allocator);
    user_task.destroy(allocator);

    // All PIDs were freed
    expectEqual(all_pids.bitmap, 1);
}

test "Multiple create" {
    var task1 = try Task.create(@ptrToInt(test_fn1), true, undefined, std.testing.allocator);
    var task2 = try Task.create(@ptrToInt(test_fn1), true, undefined, std.testing.allocator);

    expectEqual(task1.pid, 1);
    expectEqual(task2.pid, 2);
    expectEqual(all_pids.bitmap, 7);

    task1.destroy(std.testing.allocator);

    expectEqual(all_pids.bitmap, 5);

    var task3 = try Task.create(@ptrToInt(test_fn1), true, undefined, std.testing.allocator);

    expectEqual(task3.pid, 1);
    expectEqual(all_pids.bitmap, 7);

    task2.destroy(std.testing.allocator);
    task3.destroy(std.testing.allocator);

    var user_task = try Task.create(@ptrToInt(test_fn1), false, undefined, std.testing.allocator);

    expectEqual(user_task.pid, 1);
    expectEqual(all_pids.bitmap, 3);

    user_task.destroy(std.testing.allocator);
    expectEqual(all_pids.bitmap, 1);
}

test "allocatePid and freePid" {
    expectEqual(all_pids.bitmap, 1);

    var i: usize = 1;
    while (i < PidBitmap.NUM_ENTRIES) : (i += 1) {
        expectEqual(i, allocatePid());
    }

    expectEqual(all_pids.bitmap, PidBitmap.BITMAP_FULL);

    i = 0;
    while (i < PidBitmap.NUM_ENTRIES) : (i += 1) {
        freePid(@truncate(PidBitmap.IndexType, i));
    }

    expectEqual(all_pids.bitmap, 0);
}

test "createFromElf" {
    var allocator = std.testing.allocator;
    const mem_profile = mem.MemProfile{
        .vaddr_end = undefined,
        .vaddr_start = undefined,
        .physaddr_start = undefined,
        .physaddr_end = undefined,
        .mem_kb = 1024,
        .fixed_allocator = undefined,
        .virtual_reserved = &[_]mem.Map{},
        .physical_reserved = &[_]mem.Range{},
        .modules = &[_]mem.Module{},
    };
    _ = try vmm.init(&mem_profile, allocator);
    defer vmm.kernel_vmm.deinit();

    const code_address = 2345;
    const elf_data = elf.testInitData("abc123", "strings", .Executable, code_address, 0, elf.SECTION_ALLOCATABLE, 0, code_address, 0);
    defer allocator.free(elf_data);
    const the_elf = try elf.Elf.init(elf_data, builtin.arch, std.testing.allocator);
    defer the_elf.deinit();

    var the_vmm = try vmm.VirtualMemoryManager(u8).init(0, 10000, std.testing.allocator, arch.VMM_MAPPER, arch.KERNEL_VMM_PAYLOAD);
    defer the_vmm.deinit();
    const task = try Task.createFromElf(the_elf, true, &the_vmm, std.testing.allocator);
    defer task.destroy(allocator);

    std.testing.expectEqual(task.pid, 0);
    std.testing.expectEqual(task.user_stack.len, 0);
    std.testing.expectEqual(task.kernel_stack.len, STACK_SIZE);

    // Test clean-up
    var allocator2 = &std.testing.FailingAllocator.init(allocator, 0).allocator;
    std.testing.expectError(std.mem.Allocator.Error.OutOfMemory, Task.createFromElf(the_elf, true, the_vmm, allocator2));
    std.testing.expectEqual(all_pids.num_free_entries, PidBitmap.NUM_ENTRIES - 1);
}
