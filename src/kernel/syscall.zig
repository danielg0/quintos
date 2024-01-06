const std = @import("std");

const trap = @import("trap.zig");

// implement handler for UModeEnvCalls (user system calls)
// similarly to trap handling, we hold a list of function pointers that are
// called when specific system calls are made
//
// driver & service processes can register themselves as handlers for systems
// calls, which will result in system calls of that id being converted into
// messages sent to them
pub const Syscall = enum(u1) {
    SendRecieveMsg = 0,
};

// we borrow the definition of a handler function from trap.zig
pub const Handler = trap.Handler;
const HANDLER_NUM = 1 + std.math.maxInt(@typeInfo(Syscall).Enum.tag_type);
var handlers: [HANDLER_NUM]?Handler = [_]?Handler{null} ** HANDLER_NUM;

// implement an atomic-send/receive messaging primitive
// styled after the L4 implementation
