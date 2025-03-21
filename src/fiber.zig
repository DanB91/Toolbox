const toolbox = @import("toolbox.zig");
const builtin = @import("builtin");

//TODO: rename init/go/yied to fiinit/figo/fiyield

const Registers = switch (toolbox.THIS_HARDWARE) {
    .ARM64 => extern struct {
        x19_to_x30: [12]u64 align(8),
        d8_to_d15: [8]u64 align(8),
        sp: u64 align(8),
        arg: *anyopaque align(8),
    },
    .Playdate => extern struct {
        r4_to_r11: [8]u32 align(4),
        d8_to_d15: [8]u64 align(4),
        lr: u32 align(4),
        sp: u32 align(4),
        arg: *anyopaque align(4),
    },
    .AMD64 => switch (builtin.abi) {
        .gnu => extern struct {
            rbx: u64 align(8),
            r12: u64 align(8),
            r13: u64 align(8),
            r14: u64 align(8),
            r15: u64 align(8),
            rsp: u64 align(8),
            mxcsr: u64 align(8),
            fcw: u64 align(8),
            //NOTE rbp saved on stack
            arg: *anyopaque align(8),
        },
        .msvc => extern struct {
            rbx: u64 align(8),
            rbp: u64 align(8),
            rdi: u64 align(8),
            rsi: u64 align(8),
            rsp: u64 align(8),
            r12: u64 align(8),
            r13: u64 align(8),
            r14: u64 align(8),
            r15: u64 align(8),
            xmm6: u128 align(8),
            xmm7: u128 align(8),
            xmm8: u128 align(8),
            xmm9: u128 align(8),
            xmm10: u128 align(8),
            xmm11: u128 align(8),
            xmm12: u128 align(8),
            xmm13: u128 align(8),
            xmm14: u128 align(8),
            xmm15: u128 align(8),
            //NOTE rbp saved on stack
            arg: *anyopaque align(8),
        },
        else => @compileError("AMD64 OS currently unsuported"),
    },
    else => @compileError("Fibers currently unsupported"),
};

const Fiber = struct {
    registers: Registers = undefined,
    state: enum {
        Unused,
        Ready,
        Running,
    } = .Unused,
    stack: []u8,
};

const MAIN_FIBER = 0;
var g_state: struct {
    pool: []Fiber,
    current: usize,
    //must always be >=1 since the MAIN fiber is always running
    num_fibers_active: usize,
} = undefined;

pub fn init(arena: *toolbox.Arena, num_fibers: usize, stack_size: usize) void {
    if (num_fibers < 2) {
        toolbox.panic("Must have at least 2 fibers!", .{});
    }
    const pool = arena.push_slice(Fiber, num_fibers);
    g_state = .{
        .pool = pool,
        .current = MAIN_FIBER,
        .num_fibers_active = 1,
    };
    g_state.pool[MAIN_FIBER] = .{
        .state = .Running,
        .stack = undefined,
    };
    for (g_state.pool) |*r| {
        r.* = .{
            .stack = arena.push_bytes_aligned(stack_size, 16),
        };
    }
}

pub fn go(f: anytype, args: anytype, arena: *toolbox.Arena) void {
    const Args = @TypeOf(args);
    const args_ptr = arena.push(Args);
    args_ptr.* = args;
    const FiberEntry = struct {
        fn fiber_entry(arg: *Args) callconv(.C) void {
            //TODO support return values
            _ = @call(.auto, f, arg.*);
        }
    };
    switch (comptime toolbox.THIS_HARDWARE) {
        .ARM64 => go_arm64(&FiberEntry.fiber_entry, args_ptr),
        .Playdate => go_playdate(&FiberEntry.fiber_entry, args_ptr),
        .AMD64 => switch (builtin.abi) {
            .gnu => go_sys_v_amd64(&FiberEntry.fiber_entry, args_ptr),
            .msvc => go_msvc_amd64(&FiberEntry.fiber_entry, args_ptr),
            else => @compileError("Fibers unsupported on this platform!"),
        },
        else => @compileError("Fibers currently unsupported"),
    }
    g_state.num_fibers_active += 1;
}

inline fn go_arm64(fiber_entry: anytype, args: anytype) void {
    for (g_state.pool[MAIN_FIBER + 1 ..]) |*fiber| {
        if (fiber.state == .Unused) {
            const stack: []usize = @as([*]usize, @ptrCast(@alignCast(fiber.stack.ptr)))[0 .. fiber.stack.len / @sizeOf(usize)];
            stack[stack.len - 2] = @frameAddress();
            stack[stack.len - 1] = @intFromPtr(fiber_entry);
            fiber.registers.x19_to_x30[10] = @frameAddress();
            fiber.registers.x19_to_x30[11] = @intFromPtr(&ret);
            fiber.registers.sp = @intFromPtr(fiber.stack.ptr + fiber.stack.len - @sizeOf(usize) * 2);
            fiber.registers.arg = args;
            fiber.state = .Ready;
            return;
        }
    }
    toolbox.panic("Max number of fibers exceeded!", .{});
}
inline fn go_playdate(f: anytype, args: anytype) void {
    for (g_state.pool[MAIN_FIBER + 1 ..]) |*fiber| {
        if (fiber.state == .Unused) {
            const stack: []usize = @as([*]usize, @ptrCast(@alignCast(fiber.stack.ptr)))[0 .. fiber.stack.len / @sizeOf(usize)];
            stack[stack.len - 2] = @frameAddress();
            stack[stack.len - 1] = @intFromPtr(f);
            fiber.registers.r4_to_r11[3] = @frameAddress();
            fiber.registers.lr = @intFromPtr(&ret);
            fiber.registers.sp = @intFromPtr(fiber.stack.ptr + fiber.stack.len - @sizeOf(usize) * 2);
            fiber.registers.arg = args;
            fiber.state = .Ready;
            return;
        }
    }
    toolbox.panic("Max number of fibers exceeded!", .{});
}

inline fn go_sys_v_amd64(f: anytype, args: anytype) void {
    for (g_state.pool[MAIN_FIBER + 1 ..]) |*fiber| {
        if (fiber.state == .Unused) {
            const stack: []usize = @as([*]usize, @ptrCast(@alignCast(fiber.stack.ptr)))[0 .. fiber.stack.len / @sizeOf(usize)];
            stack[stack.len - 3] = @frameAddress();
            stack[stack.len - 2] = @intFromPtr(f);
            stack[stack.len - 1] = @intFromPtr(&ret);
            fiber.registers.rsp = @intFromPtr(fiber.stack.ptr + fiber.stack.len - @sizeOf(usize) * 3);
            fiber.registers.mxcsr = 0x1F80; //reset value of mxcsr
            fiber.registers.fcw = 0x37F; //reset value of fcw
            fiber.registers.arg = args;
            fiber.state = .Ready;
            return;
        }
    }
    toolbox.panic("Max number of fibers exceeded!", .{});
}

inline fn go_msvc_amd64(f: anytype, args: anytype) void {
    for (g_state.pool[MAIN_FIBER + 1 ..]) |*fiber| {
        if (fiber.state == .Unused) {
            const stack: []usize = @as([*]usize, @ptrCast(@alignCast(fiber.stack.ptr)))[0 .. fiber.stack.len / @sizeOf(usize)];
            stack[stack.len - 3] = @frameAddress();
            stack[stack.len - 2] = @intFromPtr(f);
            stack[stack.len - 1] = @intFromPtr(&ret);
            fiber.registers.rsp = @intFromPtr(fiber.stack.ptr + fiber.stack.len - @sizeOf(usize) * 3);
            fiber.registers.arg = args;
            fiber.state = .Ready;
            return;
        }
    }
    toolbox.panic("Max number of fibers exceeded!", .{});
}

pub fn yield() void {
    const old = current_fiber();
    if (old.state == .Running) {
        old.state = .Ready;
    }
    for (
        g_state.pool[g_state.current + 1 ..],
        g_state.current + 1..,
    ) |*fiber, i| {
        if (fiber.state == .Ready) {
            g_state.current = i;
            const new = current_fiber();
            new.state = .Running;
            switch_fibers(&new.registers, &old.registers);
            return;
        }
    }
    if (g_state.current == MAIN_FIBER) {
        return;
    }
    g_state.current = MAIN_FIBER;
    const new = current_fiber();
    switch_fibers(&new.registers, &old.registers);
}

pub fn ret() void {
    //Main fiber is always active
    if (g_state.current != MAIN_FIBER) {
        const r = current_fiber();
        r.state = .Unused;
        g_state.num_fibers_active -= 1;
        yield();
    }
    //TODO: maybe we should do something a little less harsh here...
    toolbox.panic("Return called on main fiber!", .{});
}

pub fn number_of_fibers_active() usize {
    return g_state.num_fibers_active;
}

inline fn current_fiber() *Fiber {
    return &g_state.pool[g_state.current];
}

extern fn switch_fibers(new: *Registers, old: *Registers) void;
comptime {
    const name = switch (builtin.os.tag) {
        .macos => "_switch_fibers",
        else => "switch_fibers",
    };
    switch (toolbox.THIS_HARDWARE) {
        .ARM64 => asm (".global " ++ name ++ "\n" ++ name ++ ":" ++
                \\
                \\#save old state registers
                \\   stp x19, x20, [x1, #0]
                \\   stp x21, x22, [x1, #0x10]
                \\   stp x23, x24, [x1, #0x20]
                \\   stp x25, x26, [x1, #0x30]
                \\   stp x27, x28, [x1, #0x40]
                \\   stp x29, x30, [x1, #0x50]
                \\   stp d8, d9, [x1, #0x60]
                \\   stp d10, d11, [x1, #0x70]
                \\   stp d12, d13, [x1, #0x80]
                \\   stp d14, d15, [x1, #0x90]
                \\
                \\#Why are we saving x29 (fp) and x30 (lr) again??
                \\#It's a hack to ret() be called automatically
                \\#when the fiber returns
                \\   sub sp, sp, #0x10
                \\   stp x29, x30, [sp]
                \\   mov x29, sp
                \\#really saving sp here, but can't use sp as operand
                \\   str x29, [x1, #0xA0]
                \\
                \\#load new state registers
                \\   ldp x19, x20, [x0, #0]
                \\   ldp x21, x22, [x0, #0x10]
                \\   ldp x23, x24, [x0, #0x20]
                \\   ldp x25, x26, [x0, #0x30]
                \\   ldp x27, x28, [x0, #0x40]
                \\   ldp x29, x30, [x0, #0x50]
                \\   ldp d8, d9, [x0, #0x60]
                \\   ldp d10, d11, [x0, #0x70]
                \\   ldp d12, d13, [x0, #0x80]
                \\   ldp d14, d15, [x0, #0x90]
                \\   ldr x4, [x0, #0xA0]
                \\   mov sp, x4
                \\
                \\   ldp x29, x4, [sp]
                \\   add sp, sp, #0x10
                \\
                \\#load arguments 
                \\   ldr x0, [x0, #0xA8]
                \\
                \\   ret x4
        ),
        .Playdate => asm (
            \\.type switch_fibers, %function
            \\switch_fibers:
            \\
            \\#save old state registers
            \\  vstmia r1!, {d8-d15}
            \\  stmia r1!, {r4-r11, lr}
            \\
            \\  push {fp, lr}
            \\  mov fp, sp
            \\  str sp, [r1]
            \\
            \\#load new state registers
            \\  vldmia r0!, {d8-d15}
            \\  ldmia r0!, {r4-r11, lr}
            \\  ldr sp, [r0]
            \\
            \\#load arguments
            \\  add r2, r0, #4
            \\  ldmia r2!, {r0}
            \\  pop {fp, pc}
        ),
        .AMD64 => switch (builtin.abi) {
            .gnu => asm (
                \\switch_fibers:
                \\# save old state registers
                \\mov %rbx, 0x0(%rsi)
                \\mov %r12, 0x8(%rsi)
                \\mov %r13, 0x10(%rsi)
                \\mov %r14, 0x18(%rsi)
                \\mov %r15, 0x20(%rsi)
                \\push %rbp #save frame address
                \\mov %rsp, 0x28(%rsi)
                \\stmxcsr 0x30(%rsi)
                \\fnstcw 0x38(%rsi)
                \\
                \\# load new state registers
                \\mov 0x0(%rdi), %rbx
                \\mov 0x8(%rdi), %r12
                \\mov 0x10(%rdi), %r13
                \\mov 0x18(%rdi), %r14
                \\mov 0x20(%rdi), %r15
                \\mov 0x28(%rdi), %rsp
                \\ldmxcsr 0x30(%rdi)
                \\fldcw 0x38(%rdi)
                \\
                \\#load arguments
                \\mov 0x40(%rdi), %rdi
                \\
                \\pop %rbp
                \\retq
            ),
            .msvc => asm (
                \\switch_fibers:
                \\# save old state registers
                \\push %rbp #save frame address
                \\mov %rbx, 0x0(%rdx)
                \\mov %rbp, 0x8(%rdx)
                \\mov %rdi, 0x10(%rdx)
                \\mov %rsi, 0x18(%rdx)
                \\mov %rsp, 0x20(%rdx)
                \\mov %r12, 0x28(%rdx)
                \\mov %r13, 0x30(%rdx)
                \\mov %r14, 0x38(%rdx)
                \\mov %r15, 0x40(%rdx)
                \\mov %xmm6, 0x48(%rdx)
                \\mov %xmm7, 0x58(%rdx)
                \\mov %xmm8, 0x68(%rdx)
                \\mov %xmm9, 0x78(%rdx)
                \\mov %xmm10, 0x88(%rdx)
                \\mov %xmm11, 0x98(%rdx)
                \\mov %xmm12, 0xA8(%rdx)
                \\mov %xmm13, 0xB8(%rdx)
                \\mov %xmm14, 0xC8(%rdx)
                \\mov %xmm15, 0xD8(%rdx)
                \\
                \\# load new state registers
                \\mov 0x0(%rcx), %rbx
                \\mov 0x8(%rcx), %rbp
                \\mov 0x10(%rcx), %rdi
                \\mov 0x18(%rcx), %rsi
                \\mov 0x20(%rcx), %rsp
                \\mov 0x28(%rcx), %r12
                \\mov 0x30(%rcx), %r13
                \\mov 0x38(%rcx), %r14
                \\mov 0x40(%rcx), %r15
                \\mov 0x48(%rcx), %xmm6
                \\mov 0x58(%rcx), %xmm7
                \\mov 0x68(%rcx), %xmm8
                \\mov 0x78(%rcx), %xmm9
                \\mov 0x88(%rcx), %xmm10
                \\mov 0x98(%rcx), %xmm11
                \\mov 0xA8(%rcx), %xmm12
                \\mov 0xB8(%rcx), %xmm13
                \\mov 0xC8(%rcx), %xmm14
                \\mov 0xD8(%rcx), %xmm15
                \\
                \\#load arguments
                \\mov 0xE8(%rcx), %rcx
                \\
                \\pop %rbp
                \\retq
            ),
            else => @compileError("AMD64 OS currently unsuported"),
        },
        else => @compileError("Fibers currently unsupported"),
    }
}
