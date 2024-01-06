# specify cross-compiler and target isa
CC      = riscv64-elf-gcc
TARGET  = -march=rv32imac -mabi=ilp32
CFLAGS  += $(TARGET) -O2
# exclude GCC clib and standard library as we provide our own
LDFLAGS += $(TARGET) -nolibc -nostdlib
# Zig compiler flags
ZFLAGS  = -target riscv32-freestanding -mcpu generic_rv32+m+a+c

# pattern rule for building zig binaries from single files
% : %.zig
	zig build-exe $(ZFLAGS) -femit-bin=$@ $<

.PHONY: all clean
all: hello fibonacci idle syscall
clean:
	rm -f hello fibonacci idle syscall *.o

hello: hello.c
fibonacci: fibonacci.c
idle: idle.s
syscall: syscall.zig
