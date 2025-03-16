const toolbox = @import("toolbox.zig");
const std = @import("std");
const Common = @This();
const c = @cImport({
    @cInclude("mach/mach_vm.h");
    @cInclude("mach/mach_init.h");
    @cInclude("unistd.h");
});

const SUPPORTS_MAGIC = toolbox.THIS_PLATFORM == .MacOS;

pub const make_ring_queue = if (SUPPORTS_MAGIC)
    make_magic_ring_queue
else
    make_not_magic_ring_queue;

pub const make_concurrent_ring_queue = if (SUPPORTS_MAGIC)
    make_concurrent_magic_ring_queue
else
    make_concurrent_not_magic_ring_queue;
pub fn RingQueue(comptime T: type) type {
    return CommonRingQueue(T, SUPPORTS_MAGIC);
}
pub fn ConcurrentRingQueue(comptime T: type) type {
    return CommonConcurrentRingQueue(T, SUPPORTS_MAGIC);
}

const Lock = if (toolbox.THIS_PLATFORM != .Emscripten)
    std.Thread.Mutex
else
    struct {
        mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

        pub fn lock(self: *Self) void {
            const result = std.c.pthread_mutex_lock(&self.mutex);
            toolbox.assert(
                result == .SUCCESS,
                "Failed to lock mutex: {}",
                .{result},
            );
        }
        pub fn unlock(self: *Self) void {
            const result = std.c.pthread_mutex_unlock(&self.mutex);
            toolbox.assert(
                result == .SUCCESS,
                "Failed to unlock mutex: {}",
                .{result},
            );
        }

        const Self = @This();
    };

const Condition = if (toolbox.THIS_PLATFORM != .Emscripten)
    std.Thread.Condition
else
    struct {
        cond: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,

        pub fn wait(self: *Self, lock: *Lock) void {
            const result = std.c.pthread_cond_wait(&self.cond, &lock.mutex);
            toolbox.assert(
                result == .SUCCESS,
                "Failed to wait on condition: {}",
                .{result},
            );
        }

        pub fn broadcast(self: *Self) void {
            const result = std.c.pthread_cond_broadcast(&self.cond);
            toolbox.assert(
                result == .SUCCESS,
                "Failed to broadcast condition: {}",
                .{result},
            );
        }

        const Self = @This();
    };

pub fn CommonRingQueue(comptime T: type, comptime _IS_MAGIC: bool) type {
    return struct {
        data: []T = toolbox.z([]T),
        rcursor: usize = 0,
        wcursor: usize = 0,
        _cap: usize = 0,

        //only for debugging
        _len: usize = 0,

        pub const IS_MAGIC = _IS_MAGIC;

        pub const Option = enum {
            PanicIfFullOrEmpty,
            AllOrNothing,
            AsMuchAsYouCan,
        };
        pub fn enqueue(q: *Q, in: []const T, comptime option: Option) usize {
            var eb1: []T = toolbox.z([]T);
            var eb2: []T = toolbox.z([]T);
            q.enqueue_buffer(
                in.len,
                option,
                &eb1,
                &eb2,
            );
            var n = @min(eb1.len, in.len);
            @memcpy(eb1[0..n], in[0..n]);

            if ((comptime !IS_MAGIC) and eb2.len > 0) {
                toolbox.assert(
                    in.len > eb1.len,
                    "We shouldn't be getting second half if eb1 is big enough for in",
                    .{},
                );
                const n2 = @min(eb2.len, in.len - eb1.len);
                @memcpy(eb2[0..n2], in[eb1.len .. eb1.len + n2]);
                n += n2;
            }
            q.update_enqueued(n);
            return n;
        }
        pub fn dequeue(q: *Q, out_buf: []T, comptime option: Option) []T {
            var db1: []T = toolbox.z([]T);
            var db2: []T = toolbox.z([]T);

            q.dequeue_buffer(
                out_buf.len,
                option,
                &db1,
                &db2,
            );
            var n = @min(db1.len, out_buf.len);
            @memcpy(out_buf[0..n], db1[0..n]);
            if ((comptime !IS_MAGIC) and db2.len > 0) {
                toolbox.assert(
                    out_buf.len > db1.len,
                    "We shouldn't be getting second half if db1 is big enough for out_buf",
                    .{},
                );
                const n2 = @min(db2.len, out_buf.len - db1.len);
                @memcpy(out_buf[db1.len .. db1.len + n2], db2[0..n2]);
                n += n2;
            }
            q.update_dequeued(n);

            const result = out_buf[0..n];
            return result;
        }
        pub fn peek(q: *Q, out_buf: []T, comptime option: Option) []T {
            var db1: []T = toolbox.z([]T);
            var db2: []T = toolbox.z([]T);

            q.dequeue_buffer(
                out_buf.len,
                option,
                &db1,
                &db2,
            );
            var n = @min(db1.len, out_buf.len);
            @memcpy(out_buf[0..n], db1[0..n]);
            if ((comptime !IS_MAGIC) and db2.len > 0) {
                toolbox.assert(
                    out_buf.len > db1.len,
                    "We shouldn't be getting second half if db1 is big enough for out_buf",
                    .{},
                );
                const n2 = @min(db2.len, out_buf.len - db1.len);
                @memcpy(out_buf[db1.len .. db1.len + n2], db2[0..n2]);
                n += n2;
            }
            q.update_dequeued(0);

            const result = out_buf[0..n];
            return result;
        }

        pub fn enqueue_one(q: *Q, v: T, comptime option: Option) bool {
            const n = q.enqueue(&.{v}, option);
            return n > 0;
        }
        pub fn dequeue_one(q: *Q, comptime option: Option) ?T {
            var buf = [1]T{undefined};
            const values = q.dequeue(&buf, option);
            var result: ?T = null;
            if (values.len > 0) {
                result = values[0];
            }
            return result;
        }
        pub fn peek_one(q: *Q, comptime option: Option) ?T {
            var buf = [1]T{undefined};
            const values = q.peek(&buf, option);
            var result: ?T = null;
            if (values.len > 0) {
                result = values[0];
            }
            return result;
        }

        pub fn dequeue_buffer(
            q: *Q,
            //null at_least implies option == .AsMuchAsYouCan, but not vice-versa
            at_least: ?usize,
            comptime option: Option,
            out_first_part: *[]T,
            //leave null if this is a magic ring queue
            out_second_part: ?*[]T,
        ) void {
            var success = true;
            if (comptime IS_MAGIC) {
                success = q.buffer_magic_common(
                    at_least,
                    option,
                    len,
                    &q.rcursor,
                    out_first_part,
                    out_second_part,
                );
            } else {
                success = q.buffer_not_magic_common(
                    at_least,
                    option,
                    len,
                    &q.rcursor,
                    out_first_part,
                    out_second_part.?,
                );
            }
            if (!success) {
                toolbox.panic("Queue unexpectedly empty!", .{});
            }
        }
        pub fn update_dequeued(q: *Q, n: usize) void {
            q.advance_cursor(&q.rcursor, n);
            q._len -= n;
            q.validate_cursors();
        }

        pub fn enqueue_buffer(
            q: *Q,
            //null at_least implies option == .AsMuchAsYouCan, but not vice-versa
            at_least: ?usize,
            comptime option: Option,
            out_first_part: *[]T,
            //leave null if this is a magic ring queue
            out_second_part: ?*[]T,
        ) void {
            var success = true;
            if (comptime IS_MAGIC) {
                success = q.buffer_magic_common(
                    at_least,
                    option,
                    unoccupied,
                    &q.wcursor,
                    out_first_part,
                    out_second_part,
                );
            } else {
                success = q.buffer_not_magic_common(
                    at_least,
                    option,
                    unoccupied,
                    &q.wcursor,
                    out_first_part,
                    out_second_part.?,
                );
            }
            if (!success) {
                toolbox.panic("Queue unexpectedly full!", .{});
            }
        }
        pub fn update_enqueued(q: *Q, n: usize) void {
            q.advance_cursor(&q.wcursor, n);
            q._len += n;
            q.validate_cursors();
        }
        pub fn len(q: *const Q) usize {
            var result: usize = 0;
            const wcursor = q.wcursor;
            const rcursor = q.rcursor;
            if (wcursor >= rcursor) {
                result = wcursor - rcursor;
            } else {
                result = (q.cap() + 1 - rcursor) + wcursor;
            }
            return result;
        }
        pub fn cap(q: *const Q) usize {
            const result = q._cap;
            return result;
        }
        pub inline fn unoccupied(q: *Q) usize {
            const result = q.cap() - q.len();
            return result;
        }

        pub fn clear(q: *Q) void {
            const l = q.len();
            q.update_dequeued(l);
        }

        fn buffer_magic_common(
            q: *Q,
            at_least: ?usize,
            comptime option: Option,
            n_func: anytype,
            cursor_field: *usize,
            out_first_part: *[]T,
            _: ?*[]T,
        ) bool {
            const _n = n_func(q);
            const n = @min(_n, at_least orelse _n);
            const cursor = cursor_field.*;
            var success = true;

            if (at_least == null or n >= at_least.?) {
                out_first_part.* = q.data[cursor .. cursor + n];
            } else {
                switch (comptime option) {
                    .AllOrNothing => {},
                    .AsMuchAsYouCan => out_first_part.* = q.data[cursor .. cursor + n],
                    .PanicIfFullOrEmpty => success = false,
                }
            }
            return success;
        }
        fn buffer_not_magic_common(
            q: *Q,
            at_least: ?usize,
            comptime option: Option,
            n_func: anytype,
            cursor_field: *usize,
            out_first_part: *[]T,
            out_second_part: *[]T,
        ) bool {
            const _n = n_func(q);
            const n = @min(_n, at_least orelse _n);
            const cursor = cursor_field.*;
            var first_n = n;
            var second_n: usize = 0;
            const dlen = q.cap() + 1;
            var success = true;

            if (dlen - cursor < n) {
                first_n = dlen - cursor;
                second_n = n - first_n;
            }
            if (at_least == null or n >= at_least.?) {
                out_first_part.* = q.data[cursor .. cursor + first_n];
                out_second_part.* = q.data[0..second_n];
            } else {
                switch (comptime option) {
                    .AllOrNothing => {},
                    .AsMuchAsYouCan => {
                        out_first_part.* = q.data[cursor .. cursor + first_n];
                        out_second_part.* = q.data[0..second_n];
                    },
                    .PanicIfFullOrEmpty => success = false,
                }
            }
            return success;
        }

        fn validate_cursors(q: *Q) void {
            if (comptime toolbox.IS_DEBUG) {
                const expected = q._len;
                const actual = q.len();
                toolbox.asserteq(
                    expected,
                    actual,
                    "Unexpected ring queue len",
                );
            }
        }
        inline fn advance_cursor(q: *Q, i: *usize, n: usize) void {
            i.* = (i.* + n) & q.cap();
        }

        const Q = @This();
    };
}

pub fn CommonConcurrentRingQueue(comptime T: type, comptime _IS_MAGIC: bool) type {
    return struct {
        data: []T = toolbox.z([]T),
        rcursor: std.atomic.Value(usize) = .{ .raw = 0 },
        wcursor: std.atomic.Value(usize) = .{ .raw = 0 },
        closed: std.atomic.Value(bool) = .{ .raw = false },
        lock: Lock = .{},
        cond: Condition = .{},
        _cap: std.atomic.Value(usize) = .{ .raw = 0 },

        //only for debugging
        _len: std.atomic.Value(usize) = .{ .raw = 0 },

        pub const IS_MAGIC = _IS_MAGIC;

        pub const Option = enum {
            Block,
            AllOrNothing,
            AsMuchAsYouCan,
        };
        pub fn enqueue(q: *Q, in: []const T, comptime option: Option) usize {
            var eb1: []T = toolbox.z([]T);
            var eb2: []T = toolbox.z([]T);
            q.enqueue_buffer(
                in.len,
                option,
                &eb1,
                &eb2,
            );
            var n = @min(eb1.len, in.len);
            @memcpy(eb1[0..n], in[0..n]);

            if ((comptime !IS_MAGIC) and eb2.len > 0) {
                toolbox.assert(
                    in.len > eb1.len,
                    "We shouldn't be getting second half if eb1 is big enough for in",
                    .{},
                );
                const n2 = @min(eb2.len, in.len - eb1.len);
                @memcpy(eb2[0..n2], in[eb1.len .. eb1.len + n2]);
                n += n2;
            }
            q.update_enqueued(n);
            return n;
        }
        pub fn dequeue(q: *Q, out_buf: []T, comptime option: Option) []T {
            var db1: []T = toolbox.z([]T);
            var db2: []T = toolbox.z([]T);

            q.dequeue_buffer(
                out_buf.len,
                option,
                &db1,
                &db2,
            );
            var n = @min(db1.len, out_buf.len);
            @memcpy(out_buf[0..n], db1[0..n]);
            if ((comptime !IS_MAGIC) and db2.len > 0) {
                toolbox.assert(
                    out_buf.len > db1.len,
                    "We shouldn't be getting second half if db1 is big enough for out_buf",
                    .{},
                );
                const n2 = @min(db2.len, out_buf.len - db1.len);
                @memcpy(out_buf[db1.len .. db1.len + n2], db2[0..n2]);
                n += n2;
            }
            q.update_dequeued(n);

            const result = out_buf[0..n];
            return result;
        }
        pub fn peek(q: *Q, out_buf: []T, comptime option: Option) []T {
            var db1: []T = toolbox.z([]T);
            var db2: []T = toolbox.z([]T);

            q.dequeue_buffer(
                out_buf.len,
                option,
                &db1,
                &db2,
            );
            var n = @min(db1.len, out_buf.len);
            @memcpy(out_buf[0..n], db1[0..n]);
            if ((comptime !IS_MAGIC) and db2.len > 0) {
                toolbox.assert(
                    out_buf.len > db1.len,
                    "We shouldn't be getting second half if db1 is big enough for out_buf",
                    .{},
                );
                const n2 = @min(db2.len, out_buf.len - db1.len);
                @memcpy(out_buf[db1.len .. db1.len + n2], db2[0..n2]);
                n += n2;
            }
            q.update_dequeued(0);

            const result = out_buf[0..n];
            return result;
        }

        pub fn enqueue_one(q: *Q, v: T, comptime option: Option) bool {
            const n = q.enqueue(&.{v}, option);
            return n > 0;
        }
        pub fn dequeue_one(q: *Q, comptime option: Option) ?T {
            var buf = [1]T{undefined};
            const values = q.dequeue(&buf, option);
            var result: ?T = null;
            if (values.len > 0) {
                result = values[0];
            }
            return result;
        }
        pub fn peek_one(q: *Q, comptime option: Option) ?T {
            var buf = [1]T{undefined};
            const values = q.peek(&buf, option);
            var result: ?T = null;
            if (values.len > 0) {
                result = values[0];
            }
            return result;
        }

        pub fn dequeue_buffer(
            q: *Q,
            //null at_least implies option == .AsMuchAsYouCan, but not vice-versa
            at_least: ?usize,
            comptime option: Option,
            out_first_part: *[]T,
            //leave null if this is a magic ring queue
            out_second_part: ?*[]T,
        ) void {
            if (comptime IS_MAGIC) {
                q.buffer_magic_common(
                    at_least,
                    option,
                    len,
                    &q.rcursor,
                    out_first_part,
                    out_second_part,
                );
            } else {
                q.buffer_not_magic_common(
                    at_least,
                    option,
                    len,
                    &q.rcursor,
                    out_first_part,
                    out_second_part.?,
                );
            }
        }
        pub fn update_dequeued(q: *Q, n: usize) void {
            var rcursor = q.rcursor.load(.acquire);
            q.advance_cursor(&rcursor, n);
            q.rcursor.store(rcursor, .release);
            _ = q._len.fetchSub(n, .acq_rel);
            q.validate_cursors();
            q.lock.unlock();
            q.cond.broadcast();
        }

        pub fn enqueue_buffer(
            q: *Q,
            //null at_least implies option == .AsMuchAsYouCan, but not vice-versa
            at_least: ?usize,
            comptime option: Option,
            out_first_part: *[]T,
            //leave null if this is a magic ring queue
            out_second_part: ?*[]T,
        ) void {
            if (comptime IS_MAGIC) {
                q.buffer_magic_common(
                    at_least,
                    option,
                    unoccupied,
                    &q.wcursor,
                    out_first_part,
                    out_second_part,
                );
            } else {
                q.buffer_not_magic_common(
                    at_least,
                    option,
                    unoccupied,
                    &q.wcursor,
                    out_first_part,
                    out_second_part.?,
                );
            }
        }
        pub fn update_enqueued(q: *Q, n: usize) void {
            var wcursor = q.wcursor.load(.acquire);
            q.advance_cursor(&wcursor, n);
            q.wcursor.store(wcursor, .release);
            _ = q._len.fetchAdd(n, .acq_rel);
            q.validate_cursors();
            q.lock.unlock();
            q.cond.broadcast();
        }
        pub fn len(q: *const Q) usize {
            var result: usize = 0;
            const wcursor = q.wcursor.load(.acquire);
            const rcursor = q.rcursor.load(.acquire);
            if (wcursor >= rcursor) {
                result = wcursor - rcursor;
            } else {
                result = (q.cap() + 1 - rcursor) + wcursor;
            }
            return result;
        }
        pub fn cap(q: *const Q) usize {
            const result = q._cap.load(.unordered);
            return result;
        }
        pub inline fn unoccupied(q: *Q) usize {
            const result = q.cap() - q.len();
            return result;
        }

        pub fn clear(q: *Q) void {
            q.lock.lock();
            const l = q.len();
            q.update_dequeued(l);
        }
        pub fn close(q: *Q) void {
            q.lock.lock();
            q.closed.store(true, .release);
            q.lock.unlock();
            q.cond.broadcast();
        }

        fn buffer_magic_common(
            q: *Q,
            at_least: ?usize,
            comptime option: Option,
            n_func: anytype,
            cursor_field: *std.atomic.Value(usize),
            out_first_part: *[]T,
            _: ?*[]T,
        ) void {
            q.lock.lock();
            retry: while (!q.closed.load(.acquire)) {
                const _n = n_func(q);
                const n = @min(_n, at_least orelse _n);
                const cursor = cursor_field.load(.acquire);
                var block = false;
                if (at_least == null or n >= at_least.?) {
                    out_first_part.* = q.data[cursor .. cursor + n];
                } else {
                    switch (comptime option) {
                        .AllOrNothing => {},
                        .AsMuchAsYouCan => out_first_part.* = q.data[cursor .. cursor + n],
                        .Block => block = true,
                    }
                }
                if (block) {
                    q.cond.wait(&q.lock);
                    continue :retry;
                }
                return;
            }
        }
        fn buffer_not_magic_common(
            q: *Q,
            at_least: ?usize,
            comptime option: Option,
            n_func: anytype,
            cursor_field: *std.atomic.Value(usize),
            out_first_part: *[]T,
            out_second_part: *[]T,
        ) void {
            q.lock.lock();
            retry: while (!q.closed.load(.acquire)) {
                const _n = n_func(q);
                const n = @min(_n, at_least orelse _n);
                const cursor = cursor_field.load(.acquire);
                var first_n = n;
                var second_n: usize = 0;
                const dlen = q.cap() + 1;
                var block = false;
                if (dlen - cursor < n) {
                    first_n = dlen - cursor;
                    second_n = n - first_n;
                }
                if (at_least == null or n >= at_least.?) {
                    out_first_part.* = q.data[cursor .. cursor + first_n];
                    out_second_part.* = q.data[0..second_n];
                } else {
                    switch (comptime option) {
                        .AllOrNothing => {},
                        .AsMuchAsYouCan => {
                            out_first_part.* = q.data[cursor .. cursor + first_n];
                            out_second_part.* = q.data[0..second_n];
                        },
                        .Block => block = true,
                    }
                }
                if (block) {
                    q.cond.wait(&q.lock);
                    continue :retry;
                }
                return;
            }
        }

        fn validate_cursors(q: *Q) void {
            if (comptime toolbox.IS_DEBUG) {
                const expected = q._len.load(.acquire);
                const actual = q.len();
                toolbox.asserteq(
                    expected,
                    actual,
                    "Unexpected ring queue len",
                );
            }
        }
        inline fn advance_cursor(q: *Q, i: *usize, n: usize) void {
            i.* = (i.* + n) & q.cap();
        }

        const Q = @This();
    };
}

pub fn make_concurrent_not_magic_ring_queue(
    comptime T: type,
    at_least_n: usize,
    arena: *toolbox.Arena,
) CommonConcurrentRingQueue(T, false) {
    const n_pow_of_2 = toolbox.next_power_of_2(at_least_n);
    const data = arena.push_slice(T, n_pow_of_2);
    const result = CommonConcurrentRingQueue(T, false){
        .data = data,
        ._cap = .{ .raw = data.len - 1 },
    };
    return result;
}
pub fn make_not_magic_ring_queue(
    comptime T: type,
    at_least_n: usize,
    arena: *toolbox.Arena,
) CommonRingQueue(T, false) {
    const n_pow_of_2 = toolbox.next_power_of_2(at_least_n);
    const data = arena.push_slice(T, n_pow_of_2);
    const result = CommonRingQueue(T, false){
        .data = data,
        ._cap = data.len - 1,
    };
    return result;
}

pub fn make_concurrent_magic_ring_queue(
    comptime T: type,
    at_least_n: usize,
    arena: *toolbox.Arena,
) CommonConcurrentRingQueue(T, true) {
    const ring_buffer = make_macos_magic_ring_buffer(
        T,
        at_least_n,
        arena,
    );
    const result = CommonConcurrentRingQueue(T, true){
        .data = ring_buffer,
        ._cap = .{ .raw = (ring_buffer.len / 2) - 1 },
    };
    return result;
}
pub fn make_magic_ring_queue(
    comptime T: type,
    at_least_n: usize,
    arena: *toolbox.Arena,
) CommonRingQueue(T, true) {
    const ring_buffer = make_macos_magic_ring_buffer(
        T,
        at_least_n,
        arena,
    );
    const result = CommonRingQueue(T, true){
        .data = ring_buffer,
        ._cap = (ring_buffer.len / 2) - 1,
    };
    return result;
}

fn make_macos_magic_ring_buffer(
    comptime T: type,
    at_least_n: usize,
    arena: *toolbox.Arena,
) []T {
    const n_pow_of_2 = toolbox.next_power_of_2(at_least_n);
    const page_size: usize = @intCast(c.getpagesize());
    var lcm = (page_size * n_pow_of_2) / std.math.gcd(page_size, n_pow_of_2);
    lcm = (lcm * @sizeOf(T)) / std.math.gcd(@sizeOf(T), lcm);

    const n_bytes = lcm;
    const n = lcm / @sizeOf(T);

    toolbox.expect(toolbox.is_power_of_2(n), "n was not a power of 2 as expected, but was: {}", .{n});

    const backing_store_bytes = arena.push_bytes_aligned_runtime(n_bytes, page_size);
    const backing_store = @as([*]T, @ptrCast(@alignCast(backing_store_bytes.ptr)))[0..n];

    var magic_ring_buffer_address_start: u64 = 0;
    const src_address = @intFromPtr(backing_store.ptr);

    const page_mask = page_size - 1;
    var protection: c.vm_prot_t = c.VM_PROT_READ | c.VM_PROT_WRITE;
    var kern_error: c.kern_return_t = 0;
    const self = c.mach_task_self();

    //allocate virtual address space
    kern_error = c.mach_vm_remap(
        self,
        &magic_ring_buffer_address_start,
        n_bytes * 2,
        page_mask,
        c.VM_FLAGS_ANYWHERE,
        self,
        src_address,
        0,
        &protection,
        &protection,
        c.VM_INHERIT_NONE,
    );
    toolbox.expect(
        kern_error == c.KERN_SUCCESS,
        "Magic ring buffer memory mapping failed! Error code: {}",
        .{kern_error},
    );

    //map actual data store into first half of address space
    kern_error = c.mach_vm_remap(
        self,
        &magic_ring_buffer_address_start,
        n_bytes,
        page_mask,
        c.VM_FLAGS_FIXED | c.VM_FLAGS_OVERWRITE,
        self,
        src_address,
        0,
        &protection,
        &protection,
        c.VM_INHERIT_NONE,
    );
    toolbox.expect(
        kern_error == c.KERN_SUCCESS,
        "Magic ring buffer memory mapping failed! Error code: {}",
        .{kern_error},
    );

    //map actual data store into second half of address space
    var ring_buffer_second_half = magic_ring_buffer_address_start + n_bytes;
    kern_error = c.mach_vm_remap(
        self,
        &ring_buffer_second_half,
        n_bytes,
        page_mask,
        c.VM_FLAGS_FIXED | c.VM_FLAGS_OVERWRITE,
        self,
        src_address,
        0,
        &protection,
        &protection,
        c.VM_INHERIT_NONE,
    );
    toolbox.expect(
        kern_error == c.KERN_SUCCESS,
        "Magic ring buffer memory mapping failed! Error code: {}",
        .{kern_error},
    );

    const ring_buffer = @as(
        [*]T,
        @ptrFromInt(magic_ring_buffer_address_start),
    )[0 .. n * 2];
    return ring_buffer;
}
