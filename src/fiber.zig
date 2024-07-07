const toolbox = @import("toolbox.zig");
const builtin = @import("builtin");

//TODO: rename init/go/yied to fiinit/figo/fiyield

const MAX_FIBER_ARGUMENTS = 2;

const Registers = if (toolbox.IS_M_SERIES_MAC)
    extern struct {
        x19_to_x30: [12]u64 align(8),
        d8_to_d15: [8]u64 align(8),
        sp: u64 align(8),
        arguments: [MAX_FIBER_ARGUMENTS]u64 align(8),
    }
else if (toolbox.IS_PLAYDATE_HARDWARE)
    //Playdate
    extern struct {
        r4_to_r11: [8]u32 align(4),
        d8_to_d15: [8]u64 align(8),
        lr: u32 align(4),
        sp: u32 align(4),
        arguments: [MAX_FIBER_ARGUMENTS]u32 align(4),
    }
else
    @compileError("Fibers unsupported on this platform!");

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
pub fn go(f: anytype, args: anytype) void {
    comptime var ti = @typeInfo(@TypeOf(f));
    switch (ti) {
        .Pointer => |ptr_info| {
            ti = @typeInfo(ptr_info.child);
            switch (ti) {
                .Fn => |fn_info| {
                    if (fn_info.params.len != args.len) {
                        @compileError("Function arguments are unexpected length");
                    }
                    inline for (fn_info.params, args) |param, arg| {
                        const ArgType = @TypeOf(arg);
                        if (param.type != ArgType) {
                            @compileError("Type mismatch in fiber argument. Got: " ++
                                @typeName(ArgType) ++ " but expected: " ++
                                @typeName(param.type.?));
                        }
                    }
                },
                else => {
                    @compileError("f must be a pointer to a function");
                },
            }
        },
        else => {
            @compileError("f must be a pointer to a function");
        },
    }
    if (args.len > MAX_FIBER_ARGUMENTS) {
        @compileError("More than " ++ MAX_FIBER_ARGUMENTS ++ " arguments not supported");
    }

    if (comptime toolbox.IS_M_SERIES_MAC) {
        go_macos(f, args);
    } else if (comptime toolbox.IS_PLAYDATE_HARDWARE) {
        go_playdate(f, args);
    } else {
        @compileError("Fibers unsupported on this platform!");
    }
}

inline fn go_macos(f: anytype, args: anytype) void {
    for (g_state.pool[MAIN_FIBER + 1 ..]) |*fiber| {
        if (fiber.state == .Unused) {
            const stack: []usize = @as([*]usize, @ptrCast(@alignCast(fiber.stack.ptr)))[0 .. fiber.stack.len / @sizeOf(usize)];
            stack[stack.len - 2] = @frameAddress();
            stack[stack.len - 1] = @intFromPtr(f);
            fiber.registers.x19_to_x30[10] = @frameAddress();
            fiber.registers.x19_to_x30[11] = @intFromPtr(&ret);
            fiber.registers.sp = @intFromPtr(fiber.stack.ptr + fiber.stack.len - @sizeOf(usize) * 2);
            inline for (args, 0..) |arg, i| {
                const ti = @typeInfo(@TypeOf(arg));
                switch (ti) {
                    .Pointer => {
                        fiber.registers.arguments[i] = @intFromPtr(arg);
                    },
                    .Int => {
                        fiber.registers.arguments[i] = @intCast(arg);
                    },
                    .ComptimeInt => {
                        fiber.registers.arguments[i] = @as(usize, arg);
                    },
                    else => @compileError("Unsupported fiber argument type"),
                }
            }
            fiber.state = .Ready;
            return;
        }
    }
    toolbox.panic("Max number of fibers exceeded!", .{});
}
inline fn go_playdate(f: anytype, args: anytype) void {
    for (g_state.pool[MAIN_FIBER + 1 ..]) |*fiber| {
        if (fiber.state == .Unused) {
            toolbox.println("in go_playdate", .{});
            const stack: []usize = @as([*]usize, @ptrCast(@alignCast(fiber.stack.ptr)))[0 .. fiber.stack.len / @sizeOf(usize)];
            stack[stack.len - 2] = @frameAddress();
            stack[stack.len - 1] = @intFromPtr(f);
            fiber.registers.r4_to_r11[3] = @frameAddress();
            fiber.registers.lr = @intFromPtr(&ret);
            fiber.registers.sp = @intFromPtr(fiber.stack.ptr + fiber.stack.len - @sizeOf(usize) * 2);
            inline for (args, 0..) |arg, i| {
                const ti = @typeInfo(@TypeOf(arg));
                switch (ti) {
                    .Pointer => {
                        fiber.registers.arguments[i] = @intFromPtr(arg);
                    },
                    .Int => {
                        fiber.registers.arguments[i] = @intCast(arg);
                    },
                    .ComptimeInt => {
                        fiber.registers.arguments[i] = @as(usize, arg);
                    },
                    else => @compileError("Unsupported fiber argument type"),
                }
            }
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
            g_state.num_fibers_active += 1;
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
        _ = yield();
    }
}

pub fn number_of_fibers_active() usize {
    return g_state.num_fibers_active;
}

inline fn current_fiber() *Fiber {
    return &g_state.pool[g_state.current];
}

extern fn switch_fibers(new: *Registers, old: *Registers) void;
comptime {
    if (toolbox.IS_M_SERIES_MAC) {
        asm (
            \\.global _switch_fibers
            \\_switch_fibers:
            \\
            \\;save old state registers
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
            \\;Why are we saving x29 (fp) and x30 (lr) again??
            \\;It's a hack to ret() be called automatically
            \\;when the fiber returns
            \\   sub sp, sp, #0x10
            \\   stp x29, x30, [sp]
            \\   mov x29, sp
            \\;really saving sp here, but can't use sp as operand
            \\   str x29, [x1, #0xA0]
            \\
            \\;load new state registers
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
            \\;load arguments 
            \\   ldp x0, x1, [x0, #0xA8]
            \\
            \\   ret x4
        );
    } else if (toolbox.IS_PLAYDATE_HARDWARE) {
        asm (
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
            \\  ldmia r2!, {r0, r1}
            \\  pop {fp, pc}
        );
    } else {
        @compileError("Fibers not yet supported!");
    }
}
