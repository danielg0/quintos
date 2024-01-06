const uart: *u8 = @ptrFromInt(0x5000);

export fn main() void {
    // make a system call
    // trashes any riscv caller saved registers
    const result = asm (
        \\ ecall
        : [result] "={a0}" (-> u32),
        : [arg0] "{a0}" (42),
        : "x1", "x5", "x6", "x7", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "x28", "x29", "x30", "x31"
    );

    // print out what we got back
    _ = result;
}

export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\   call main
        \\   j 0
    );
}
