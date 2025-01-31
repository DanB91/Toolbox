const toolbox = @import("toolbox.zig");
const builtin = @import("builtin");
const std = @import("std");
comptime {
    switch (toolbox.THIS_PLATFORM) {
        .MacOS, .Playdate, .Linux, .BoksOS, .Emscripten => {},
        else => {
            if (builtin.target.cpu.arch != .x86_64) {
                @compileError("We only support AMD64 if platform isn't macOS or Playdate");
            }
        },
    }
}

pub const MAX_DURATION = Duration{
    .ticks = switch (toolbox.THIS_PLATFORM) {
        .MacOS => std.math.maxInt(i64),
        .Emscripten => std.math.floatMax(f64),
        .Playdate => std.math.floatMax(f32),
        else => std.math.maxInt(i64),
    },
};
pub const Duration = struct {
    ticks: Ticks = 0,

    pub const Ticks = switch (toolbox.THIS_PLATFORM) {
        .Playdate => f32,
        .Emscripten => f64,
        else => i64,
    };

    const PlatformDuration = switch (toolbox.THIS_PLATFORM) {
        .MacOS, .Linux => UnixDuration,
        .Playdate => PlaydateDuration,
        .Emscripten => EmscriptenDuration,
        else => AMD64Duration,
    };

    pub inline fn add(lhs: Duration, rhs: Duration) Duration {
        return .{ .ticks = lhs.ticks + rhs.ticks };
    }
    pub inline fn subtract(lhs: Duration, rhs: Duration) Duration {
        return .{ .ticks = lhs.ticks - rhs.ticks };
    }

    pub const from_nanoseconds = @field(PlatformDuration, "from_nanoseconds");
    pub const from_microseconds = @field(PlatformDuration, "from_microseconds");
    pub const from_milliseconds = @field(PlatformDuration, "from_milliseconds");
    pub const from_seconds = @field(PlatformDuration, "from_seconds");
    pub const nanoseconds = @field(PlatformDuration, "nanoseconds");
    pub const microseconds = @field(PlatformDuration, "microseconds");
    pub const milliseconds = @field(PlatformDuration, "milliseconds");
    pub const seconds = @field(PlatformDuration, "seconds");
};

pub var amd64_ticks_to_microseconds: i64 = 0;

pub const Nanoseconds = Milliseconds;
pub const Microseconds = Milliseconds;
pub const Milliseconds = switch (toolbox.THIS_PLATFORM) {
    .Playdate => i32,
    .Emscripten => f64,
    else => i64,
};
pub const Seconds = switch (toolbox.THIS_PLATFORM) {
    .Playdate => f32,
    else => f64,
};
pub fn now() Duration {
    switch (comptime toolbox.THIS_PLATFORM) {
        .MacOS => {
            const ctime = @cImport(@cInclude("time.h"));
            const nanos = ctime.clock_gettime_nsec_np(ctime.CLOCK_MONOTONIC_RAW);
            toolbox.assert(nanos != 0, "nanotime call failed!", .{});
            return .{ .ticks = @intCast(nanos) };
        },
        .Linux => {
            if (comptime toolbox.THIS_HARDWARE == .ARM64) {
                const ctime = @cImport(@cInclude("time.h"));
                var tp = ctime.struct_timespec{};
                const result = ctime.clock_gettime(
                    ctime.CLOCK_MONOTONIC_RAW,
                    &tp,
                );
                toolbox.expecteq(0, result, "clock_gettime() call failed.");
                const ticks = tp.tv_nsec;

                return .{ .ticks = ticks };
            } else {
                const result = amd64_read_time();
                return result;
            }
        },
        .Playdate => {
            return .{ .ticks = toolbox.playdate_get_seconds() };
        },
        .BoksOS => {
            switch (comptime toolbox.THIS_HARDWARE) {
                .AMD64 => {
                    const result = amd64_read_time();
                    return result;
                },
                .ARM64 => {
                    const result = aarch64_read_time();
                    return result;
                },
                else => @compileError("Unsupported hardware for BoksOS"),
            }
        },
        .Emscripten => {
            const C = struct {
                extern fn emscripten_get_now() f64;
            };
            const result = Duration{ .ticks = C.emscripten_get_now() };
            return result;
        },
        else => {
            const result = amd64_read_time();
            return result;
        },
    }
}
fn amd64_read_time() Duration {
    var top: u64 = 0;
    var bottom: u64 = 0;
    asm volatile (
        \\rdtsc
        : [top] "={edx}" (top),
          [bottom] "={eax}" (bottom),
    );
    const tsc = (top << 32) | bottom;
    return .{ .ticks = @intCast(tsc) };
}
fn aarch64_read_time() Duration {
    const result = asm volatile (
        \\mrs %[ticks], cntvct_el0
        : [ticks] "=r" (-> u64),
    );
    return .{ .ticks = @intCast(result) };
}

const AMD64Duration = struct {
    pub inline fn from_nanoseconds(ns: Nanoseconds) Duration {
        const result = from_microseconds(ns / 1000);
        return result;
    }
    pub inline fn from_microseconds(mcs: Microseconds) Duration {
        toolbox.assert(amd64_ticks_to_microseconds > 0, "TSC calibration was not performed", .{});
        const result = Duration{
            .ticks = mcs * amd64_ticks_to_microseconds,
        };
        return result;
    }
    pub inline fn from_milliseconds(ms: Milliseconds) Duration {
        const result = from_microseconds(ms * 1000);
        return result;
    }
    pub inline fn from_seconds(sec: Seconds) Duration {
        const sec_int: Microseconds = @intFromFloat(sec);
        const result = from_microseconds(sec_int * 1_000_000);
        return result;
    }
    pub inline fn nanoseconds(self: Duration) Nanoseconds {
        return self.microseconds() * 1000;
    }
    pub inline fn microseconds(self: Duration) Microseconds {
        toolbox.assert(amd64_ticks_to_microseconds > 0, "TSC calibration was not performed", .{});
        return @divTrunc(
            self.ticks,
            amd64_ticks_to_microseconds,
        );
    }
    pub inline fn milliseconds(self: Duration) Milliseconds {
        return @divTrunc(self.microseconds(), 1000);
    }
    pub inline fn seconds(self: Duration) Seconds {
        const floating_point_mcs: Seconds = @floatFromInt(self.microseconds());
        return floating_point_mcs / 1_000_000.0;
    }
};

const AArch64Duration = struct {
    fn frequency() u64 {
        const result = asm volatile ("mrs %[freq], cntfrq_el0"
            : [freq] "r" (-> u64),
        );
        return result;
    }
};

const UnixDuration = struct {
    pub inline fn from_nanoseconds(ns: Nanoseconds) Duration {
        const result = Duration{ .ticks = ns };
        return result;
    }
    pub inline fn from_microseconds(mcs: Microseconds) Duration {
        const result = from_nanoseconds(mcs * 1000);
        return result;
    }
    pub inline fn from_milliseconds(ms: Milliseconds) Duration {
        const result = from_nanoseconds(ms * 1_000_000);
        return result;
    }
    pub inline fn from_seconds(sec: Seconds) Duration {
        const sec_int: Nanoseconds = @intFromFloat(sec);
        const result = from_nanoseconds(sec_int * 1_000_000_000);
        return result;
    }
    pub inline fn nanoseconds(self: Duration) Nanoseconds {
        return self.ticks;
    }
    pub inline fn microseconds(self: Duration) Microseconds {
        return @divTrunc(self.ticks, 1000);
    }
    pub inline fn milliseconds(self: Duration) Milliseconds {
        return @divTrunc(self.ticks, 1_000_000);
    }
    pub inline fn seconds(self: Duration) Seconds {
        const floating_point_ns: Seconds = @floatFromInt(self.ticks);
        return floating_point_ns / 1_000_000_000.0;
    }
};
const PlaydateDuration = struct {
    pub inline fn from_nanoseconds(ns: Nanoseconds) Duration {
        const ns_float: Seconds = @intFromFloat(ns);
        const result = from_seconds(ns_float / 1_000_000_000);
        return result;
    }
    pub inline fn from_microseconds(mcs: Microseconds) Duration {
        const mcs_float: Seconds = @intFromFloat(mcs);
        const result = from_seconds(mcs_float / 1_000_000);
        return result;
    }
    pub inline fn from_milliseconds(ms: Milliseconds) Duration {
        const ms_float: Seconds = @intFromFloat(ms);
        const result = from_seconds(ms_float / 1000);
        return result;
    }
    pub inline fn from_seconds(sec: Seconds) Duration {
        const result = Duration{ .ticks = sec };
        return result;
    }
    pub inline fn nanoseconds(self: Duration) Nanoseconds {
        return @intFromFloat(self.ticks * 1_000_000_000.0);
    }
    pub inline fn microseconds(self: Duration) Microseconds {
        return @intFromFloat(self.ticks * 1_000_000.0);
    }
    pub inline fn milliseconds(self: Duration) Milliseconds {
        return @intFromFloat(self.ticks * 1000.0);
    }
    pub inline fn seconds(self: Duration) Seconds {
        return self.ticks;
    }
};

const EmscriptenDuration = struct {
    pub inline fn from_nanoseconds(ns: Nanoseconds) Duration {
        const result = from_milliseconds(ns / 1_000_000);
        return result;
    }
    pub inline fn from_microseconds(mcs: Microseconds) Duration {
        const result = from_milliseconds(mcs / 1_000);
        return result;
    }
    pub inline fn from_milliseconds(ms: Milliseconds) Duration {
        const result = Duration{ .ticks = ms };
        return result;
    }
    pub inline fn from_seconds(sec: Seconds) Duration {
        const result = from_milliseconds(sec * 1_000);
        return result;
    }
    pub inline fn nanoseconds(self: Duration) Nanoseconds {
        return self.ticks * 1_000_000.0;
    }
    pub inline fn microseconds(self: Duration) Microseconds {
        return self.ticks * 1_000.0;
    }
    pub inline fn milliseconds(self: Duration) Milliseconds {
        return self.ticks;
    }
    pub inline fn seconds(self: Duration) Seconds {
        return self.ticks / 1_000.0;
    }
};
