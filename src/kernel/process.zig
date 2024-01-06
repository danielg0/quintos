const std = @import("std");
const StructList = @import("struct_list.zig").StructList;
const paging = @import("paging.zig");

const log = std.log.scoped(.process);

const NAME_LEN = 16;
const Name = [NAME_LEN]u8;

// unique, kernel-wide identifier for each process
pub const Id = u8;

pub const MAGIC = 0x242;

// define riscv registers saved
// TODO: move to riscv.zig file?
// extern to ensure a specific ordering
pub const Registers = extern struct {
    ra: u32 = 0,
    sp: u32 = 0,
    gp: u32 = 0,
    tp: u32 = 0,
    t0: u32 = 0,
    t1: u32 = 0,
    t2: u32 = 0,
    s0: u32 = 0,
    s1: u32 = 0,
    a0: u32 = 0,
    a1: u32 = 0,
    a2: u32 = 0,
    a3: u32 = 0,
    a4: u32 = 0,
    a5: u32 = 0,
    a6: u32 = 0,
    a7: u32 = 0,
    s2: u32 = 0,
    s3: u32 = 0,
    s4: u32 = 0,
    s5: u32 = 0,
    s6: u32 = 0,
    s7: u32 = 0,
    s8: u32 = 0,
    s9: u32 = 0,
    s10: u32 = 0,
    s11: u32 = 0,
    t3: u32 = 0,
    t4: u32 = 0,
    t5: u32 = 0,
    t6: u32 = 0,
};

pub const Process = struct {
    const Self = @This();

    pub const State = enum {
        RUNNING,
        READY,
        BLOCKED,
        DYING,
        DEAD, // when dead a process' pc is the next free id number
    };

    // unique, kernel-wide identifier for this process
    id: Id,
    name: Name,
    state: State,

    // holds registers whilst this process isn't running
    saved: Registers = .{},

    // address we faulted on in virtual address space
    // also the process' initial entry point
    pc: usize,

    // fault cause address
    // eg. for page faults this holds the address in memory we tried to access
    fault_cause: usize = 0,

    // list elements for the all processes and ready/blocked lists
    elem: StructList.Elem = .{},

    // pointer to this process' root page table
    page_table: paging.PageTablePtr,

    // magic value we can check for when given a process pointer to check that
    // it's valid (probably)
    magic: u32 = MAGIC,

    // log function for a process
    // we have to write our own because the definition of Process contains
    // structlist elems, which are recursive
    pub fn print(self: *Self) void {
        log.debug("Process #{d}", .{self.id});
        log.debug("  name: '{s}'", .{self.name});
        log.debug("  state: {}", .{self.state});
        log.debug("  program counter: 0x{x}", .{self.pc});
        log.debug("  fault cause: 0x{x}", .{self.fault_cause});
        log.debug("  saved: {any}", .{self.saved});
    }
};

// convert a u8 slice (eg. a string literal) to a process name
// truncates literals that are too long
pub fn name(literal: []const u8) Name {
    var arr: Name = [_]u8{0} ** NAME_LEN;
    const len = @min(literal.len, NAME_LEN);
    for (literal[0..len], 0..) |c, i| {
        arr[i] = c;
    }
    return arr;
}
