const std = @import("std");
const assert = std.debug.assert;

const paging = @import("paging.zig");
const process = @import("process.zig");
const schedule = @import("schedule.zig");

const log = std.log.scoped(.trap);

// in RISCV, traps have two types of causes, interrupts and exceptions. We want
// to be able to register handlers for both types (eg. a software interrupt is
// an interrupt, and a page fault is an exception)
// I'm choosing to ignore traps designed for custom and platform use, which
// means the highest exception code we need to handle is 15, so all exception &
// interrupt codes conveniently fit into 4 bits

// see mcause register definition in RISCV privileged spec
// Trap is an enum for referring to the different types of interrupt/exception
// exceptions (ie. mcause interrupt bit = 0) will have values 0-15
// interrupts (ie. mcause interrupt bit = 1) will have values 16-31
pub const Trap = enum(u5) {
    // exceptions
    InstrAddrMisalign = 0,
    InstrAccFault = 1,
    IllegalInstr = 2,
    Breakpoint = 3,
    LoadAddrMisalign = 4,
    LoadAccFault = 5,
    StoreAddrMisalign = 6,
    StoreAccFault = 7,
    UModeEnvCall = 8,
    SModeEnvCall = 9,
    MModeEnvCall = 11,
    InstrPageFault = 12,
    LoadPageFault = 13,
    StorePageFault = 15,
    // interrupts
    SModeSoftware = 17,
    MModeSoftware = 19,
    SModeTimer = 21,
    MModeTimer = 23,
    SModeExternal = 25,
    MModeExternal = 27,
    // other custom/reserved interrupts
    _,
};

// array of function pointers to trap handlers
// index for a given interrupt/exception's handler is its value in the Trap enum
//
// trap handlers can modify the current running process by modifying the
// running struct, and can choose what happens when they return by setting its
// state to:
//   .RUNNING => the running process keeps running
//   .BLOCKED => the running process is blocked and another is scheduled
//   .READY   => the running process is switched out for another
//   .DYING   => the running process is killed
pub const Handler = *const fn (running: *process.Process) callconv(.C) void;
const HANDLER_NUM = 1 + std.math.maxInt(@typeInfo(Trap).Enum.tag_type);
var handlers: [HANDLER_NUM]?Handler = [_]?Handler{null} ** HANDLER_NUM;

// functions for registering/unregistering handlers
// should always be functions in kernel space (ie. message send primitives)
pub fn register(trap: Trap, handler: Handler) !void {
    // check we don't already have a handler for that trap
    if (handlers[@intFromEnum(trap)] != null)
        return error.TrapAlreadyRegistered;
    // TODO: add check for kernel space?
    handlers[@intFromEnum(trap)] = handler;
}
pub fn unregister(trap: Trap) void {
    handlers[@intFromEnum(trap)] = null;
}

// initialise traps
// setup stub for handling traps
pub fn init() void {
    // write address of where to jump on a trap to mtvec
    // it needs to be aligned to 4 bytes, leaving the lower 2 bits for us to use
    // to specify the "mode"
    // riscv-privileged-20211203.pdf#subsection.3.1.7
    const Mode = enum(u2) {
        DIRECT = 0,
        VECTORED = 1,
    };
    const mode = Mode.DIRECT;
    const base_address: usize = @intFromPtr(&trap_stub) | @intFromEnum(mode);

    asm volatile ("csrw mtvec, %[base]"
        :
        : [base] "r" (base_address),
    );

    // enable the handling of all (standard) interrupts by setting the first 16
    // bits of mie
    asm volatile ("csrw mie, %[enabled]"
        :
        : [enabled] "r" (0xffff),
    );
}

// trap stub
// we enter into this function in machine mode whenever a trap occurs
// we need to save the interrupted process state, then call into the relevent
// kernel trap handler, then return to the same or a new process
// When we are in user-mode, we store a pointer to the currently running user
// process in the mscratch csr
fn trap_stub() align(4) callconv(.Naked) noreturn {
    // NOTE: we don't need to disable interrupts whilst we handle a trap
    //
    // In riscv, when we're in user mode, any interrupt x traps to machine mode
    // so long as the xth bit is set in the mie csr. When in machine mode, it's
    // controlled by the MIE flag in the mstatus csr. If we leave it unset, that
    // means we'll never interrupt whilst handling an interrupt, as we handle
    // traps in machine mode.
    // ie. interrupts are always disabled in the kernel
    //
    // We still need to handle exceptions that occur whilst handling the trap,
    // but they shouldn't occur in bug-free handlers, so we'll just panic
    //
    // TODO: What about page faults? If a handler wants to copy something into
    // userspace (ie. a string message) and that page isn't loaded yet
    // How about the function that checks the validity of a userspace pointer
    // also forces it to be paged in??
    // Alternatively, whenever a function writes to user memory, perhaps it
    // could temporarily change mtvec??

    // extract the process saved array from mscratch, validate it, then write
    // registers to it and enable the trap handling stack
    const running: *process.Process = asm volatile (
        \\ csrw sscratch, x31
        // x31 saved to sscratch so we can get it back later
        \\ csrr x31, mscratch
        // as running pointer still in mscratch, we can trash the value in x31

        // make sure pointer is in kernel space
        // (ie. between 0x8000 0000 and 0xbfff ffff inclusive)
        // TODO: update this value (ie. constrain it to the heap we use for
        // allocating user processes - see paging.zig)
        // if not, go to kernel_panic, which logs some info and halts

        // as pointers are 32 bits, we're shifting out all but the last nibble
        \\ srli x31, x31, 28
        // then by subtracting 8, the range of values we want is 0 to 3
        // inclusive, so we can just check if it's less than 4 unsigned
        \\ addi x31, x31, -8
        \\ sltiu x31, x31, 4
        \\ beqz x31, invalid_running
        // add the length of the struct to the base pointer and make sure that
        // is in range as well
        \\ csrr x31, mscratch
        \\ addi x31, x31, %[sizeof_process]
        // check in range 0x8000 0000 to 0xbfff ffff inclusive
        \\ srli x31, x31, 28
        \\ addi x31, x31, -8
        \\ sltiu x31, x31, 4
        \\ beqz x31, invalid_running

        // check magic value in pointer struct
        \\ csrr x31, mscratch
        \\ lw x31, %[off_magic](x31)
        \\ add x31, x31, -%[magic]
        \\ bnez x31, invalid_running

        // pointer to struct should be safe to save registers to now
        \\ csrr x31, mscratch
        // get pointer to saved array from retrieved process struct pointer
        \\ addi x31, x31, %[off_saved]
        // we've put one user register into mscratch, we'll retrieve it later
        // save all registers into process saved array
        \\ .irp reg,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30
        \\ sw x\reg, (x31)
        \\ addi x31, x31, 4
        \\ .endr
        // x31 now holds a pointer to the very last element of the array
        // retrieve the original value of x31 and save it
        \\ csrr x30, sscratch
        \\ sw x30, (x31)
        // subtract from x31 to get the base of the array
        // x31 - x1 = 30 * 4bytes = 120 bytes
        \\ addi x31, x31, -120
        // from that, get the base pointer to the process struct
        \\ addi x31, x31, -%[off_saved]
        // write the pointer to the process back into mscratch
        \\ csrw mscratch, x31

        // save the address that cause the fault into the process structure
        \\ csrr x30, mepc
        \\ sw x30, %[off_pc](x31)
        \\ csrr x30, mtval
        \\ sw x30, %[off_fault_cause](x31)

        // switch to the per-hart trap stack
        // this is so that the process can't screw with us by maliciously
        // setting sp to point to some random part of memory before making a
        // system call
        // remember, stack starts from the end/high-end and grows back/lower
        \\ la sp, _stack_end
        \\ mv fp, sp
        : [process] "={x31}" (-> *process.Process),
        : [sizeof_process] "i" (@sizeOf(process.Process)),
          [off_saved] "i" (@offsetOf(process.Process, "saved")),
          [off_magic] "i" (@offsetOf(process.Process, "magic")),
          [magic] "i" (process.MAGIC),
          [off_pc] "i" (@offsetOf(process.Process, "pc")),
          [off_fault_cause] "i" (@offsetOf(process.Process, "fault_cause")),
    );

    // jump into zig handler
    // it will get the type of trap that occurred and call into its handler
    _ = asm volatile (
        \\ jalr %[handler]
        :
        : [handler] "r" (&trap_handler),
          [running] "{a0}" (running),
          // this is jump into a function following C calling convention, so any
          // caller-saved registers could be trashed
          // these are listed in riscv-spec-20191213.pdf Chapter25
        : "ra", "t0", "t1", "t2", "t3", "t4", "t5", "t6", "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7"
    );

    // restore registers and go back to user mode
    // if any rescheduling occured, it has updated the pointer in mscratch, so
    // we should restore from that rather than use running
    _ = asm volatile (
        \\ csrr x31, mscratch
        // restore pc from process struct
        \\ lw x30, %[off_pc](x31)
        \\ csrw mepc, x30

        // get pointer to saved array
        \\ addi x31, x31, %[off_saved]
        // read all registers from process saved array
        \\ .irp reg,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30
        \\ lw x\reg, (x31)
        \\ addi x31, x31, 4
        \\ .endr
        // write to the last register
        // not in loop so we don't add to the restored value
        \\ lw x31, (x31)
        // go back to user mode
        \\ mret
        :
        : [off_saved] "i" (@offsetOf(process.Process, "saved")),
          [off_pc] "i" (@offsetOf(process.Process, "pc")),
    );

    // we trapped but the process pointer stored in mscratch is either not in
    // kernel space, or is missing the magic value, so call trap_panic
    // we reset back to the hart stack before jumping to avoid any other traps
    // due to bad memory accesses
    _ = asm volatile (
        \\ invalid_running:
        \\ la sp, _stack_end
        \\ csrr a0, mepc
        \\ csrr a1, mscratch
        \\ j %[trap_panic]
        :
        : [trap_panic] "i" (&trap_panic),
        : "a0", "a1", "sp"
    );
}

// called into on every trap
// logs the trap and causer, then calls into its handler
fn trap_handler(running: *process.Process) callconv(.C) void {
    assert(running.state == .RUNNING);

    // get what sort of trap occured
    // msb is whether it's interrupt or trap, lowest 4 bits are the code
    const mcause = asm volatile (
        \\ csrr %[mcause], mcause
        : [mcause] "=r" (-> u32),
    );
    const trap: Trap = @enumFromInt(@as(u4, @truncate(mcause)) |
        (0b10000 & @as(u5, @truncate(mcause >> 27))));

    // get the level we were at when we trapped
    const level = asm volatile (
        \\ csrr %[mpp], mstatus
        \\ srai %[mpp], %[mpp], 11
        \\ andi %[mpp], %[mpp], 3
        : [mpp] "=r" (-> u2),
    );

    // log trap and process that caused it
    log.info("Recived {} at level {d}", .{ trap, level });
    log.info("mscratch holds Process #{d} \"{s}\"", .{ running.id, running.name });
    running.print();

    // call into handler
    // it may modify the process struct to change its registers, cause it to
    // become blocked/unscheduled or add new mappings to its pagetable
    const handler = handlers[@intFromEnum(trap)] orelse @panic("No handler for trap!");
    handler(running);

    // find what process is running next
    const next = schedule.next(running);

    // reload the page table for the next process, also fence so changes apply
    paging.enable(next.page_table);
    // load the next process into mscratch
    _ = asm volatile ("csrw mscratch, %[next]"
        :
        : [next] "r" (next),
    );

    log.info("Trap handled, scheduling \"{s}\"", .{next.name});
}

// zig trap panic handler
fn trap_panic(pc: u32, running: u32) callconv(.C) noreturn {
    log.err("Got a fault at: 0x{x} - mscratch had invalid value: 0x{x}", .{ pc, running });
    @panic("Trap Panic!");
}
