const std = @import("std");
const builtin = std.builtin;

const fdtb = @import("boot/fdtb.zig");
const paging = @import("kernel/paging.zig");
const process = @import("kernel/process.zig");
const schedule = @import("kernel/schedule.zig");
const syscon = @import("kernel/syscon.zig");
const timer = @import("kernel/timer.zig");
const trap = @import("kernel/trap.zig");
const uart = @import("kernel/uart.zig");

const enabled_fdtb = false;

// zig entry point called from boot/start.s
// first argument is a pointer to the flattened device tree blob
export fn entry(fdtb_blob: ?[*]const u8) noreturn {
    // TODO: replace device tree blob printer with service that runs driver
    // processes for found devices
    if (enabled_fdtb) {
        if (fdtb_blob) |blob| {
            fdtb.print(blob, uart.out) catch |e| {
                std.log.err("FDTB parse error! {s}", .{@errorName(e)});
                syscon.poweroff();
            };
        } else {
            std.log.err("FDTB pointer null!", .{});
            syscon.poweroff();
        }
    }

    kinit() catch |e| {
        std.log.err("Kernel panic! {s}", .{@errorName(e)});
        syscon.poweroff();
    };
}

// override standard library logging function with the uart one
pub const std_options = struct {
    pub const logFn = uart.log;
    pub const log_level = .info;
};

// kernel main initialisation function
// initialises kernel data structures and kickstarts core services
// once we go into the first process, we never return to kinit, so we can use
// the kernel stack for trap handling
fn kinit() !noreturn {
    // initialise trap handling - should be first thing we do so we get errors
    // if something fails during initialisation
    trap.init();

    // initialise paging and process scheduling
    try paging.init();
    try schedule.init();

    // setup kernel device drivers
    timer.init();

    // start required processes

    // page address and mapping for uart (we map this a couple times)
    const uart_pa = 0x10000000;
    const uart_va = 0x5000;
    const user_uart = [_]schedule.Mapping{.{ .virt = uart_va, .phys = uart_pa, .r = true, .w = true }};

    // a hello world C program
    _ = try schedule.createMapped("hello", @embedFile("user/programs/hello"), &user_uart);
    // a fibonacci C program
    const fib = try schedule.createMapped("fib", @embedFile("user/programs/fibonacci"), &user_uart);
    // a zig program that makes system calls
    _ = try schedule.createMapped("syscall", @embedFile("user/programs/syscall"), &user_uart);

    // setup done, display welcome message
    std.log.info("Welcome to QuartOS", .{});

    // initial process
    // we pull it out manually because scheduling assumes we have a running
    // process that isn't in any ready lists
    const init = fib;
    init.elem.remove();
    init.state = .RUNNING;

    // set a timer for the end of the first slice
    timer.set(timer.offset(timer.slice));

    // enable paging for the initial process
    paging.enable(init.page_table);

    // attempt to go into user mode
    _ = asm volatile (
        \\ csrw mepc, %[pc]
        // ^ setup initial program counter of user program

        // disable memory protection (TODO: remove this)
        \\ csrwi pmpcfg0, 0x1f
        \\ li t0, -1
        \\ csrw pmpaddr0, t0

        // fence here after disabling memory protection
        // as it could modify whether page faults occur
        \\ sfence.vma

        // save pointer to process to mscratch
        \\ csrw mscratch, %[running]

        // specify that we return to user mode
        \\ li t0, 0x1800
        \\ csrc mstatus, t0

        // read initial register values from saved array
        // this needs to be the last thing we do because it trashes every reg
        \\ addi x31, x31, %[off_saved]
        // read all registers from process saved array
        \\ .irp reg,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30
        \\ lw x\reg, (x31)
        \\ addi x31, x31, 4
        \\ .endr
        // write to the last register
        // not in loop so we don't add to the restored value
        \\ lw x31, (x31)

        // "return from a trap" (ie. jump to mepc as a user)
        \\ mret
        :
        : [pc] "r" (init.pc),
          [running] "{x31}" (init),
          [off_saved] "i" (@offsetOf(process.Process, "saved")),
        : "t0"
    );

    // we should never get back here, any traps in future should goto trap stub
    unreachable;
}

pub fn panic(msg: []const u8, error_return_trace: ?*builtin.StackTrace, siz: ?usize) noreturn {
    _ = error_return_trace;
    _ = siz;

    std.log.err("Zig panic! {s}", .{msg});
    syscon.poweroff();
}
