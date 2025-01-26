const std = @import("std");
const toolbox = @import("toolbox.zig");
const profiler = toolbox.profiler;
const fiber = toolbox.fiber;

pub const ENABLE_PROFILER = true; // !toolbox.IS_DEBUG;
pub const panic = toolbox.panic_handler;

pub fn main() void {
    //TODO: test arena up here
    var arena = toolbox.Arena.init(toolbox.mb(1));
    defer arena.free_all();

    //TODO: uncomment after solving removal bug
    if (toolbox.IS_DEBUG) {
        run_tests(arena) catch unreachable;
        // run_benchmarks();
    } else {
        run_tests(arena) catch unreachable;
        run_benchmarks();
    }
}

//TODO
//enum {
//Print,
//TypeUtils,
//Memory,
//LinkedList,
//All,
//};

fn run_tests(arena: *toolbox.Arena) !void {

    //print tests
    {
        toolbox.println("Hello world!", .{});
        toolbox.println("Hello number: {}!", .{1.0234});
        toolbox.printerr("Hello error!", .{});
        //toolbox.panic("Hello panic!", .{});
    }

    //type utils tests
    {
        const i: i32 = 5;
        const string_slice: []const u8 = "Hello!";

        //iterable tests
        toolbox.expect(toolbox.is_iterable([]u8), "Byte slice should be iterable!", .{});
        toolbox.expect(!toolbox.is_iterable(i), "Number should not be iterable!", .{});
        toolbox.expect(!toolbox.is_iterable(&i), "Address-of number should not be iterable!", .{});
        toolbox.expect(toolbox.is_iterable("This is iterable"), "String should be iterable!", .{});
        toolbox.expect(toolbox.is_iterable(string_slice), "String should be iterable!", .{});

        //single pointer tests
        toolbox.expect(!toolbox.is_single_pointer(i), "Number should not be a single pointer!", .{});
        toolbox.expect(toolbox.is_single_pointer(&i), "Address-of should be a single pointer!", .{});
        toolbox.expect(toolbox.is_single_pointer("Strings are single pointers to arrays"), "Strings should be a single pointer to arrays", .{});
        toolbox.expect(!toolbox.is_single_pointer(string_slice), "Slices should not be a single pointer", .{});
    }

    //memory tests
    {
        //test system allocator
        {
            const num_bytes = toolbox.mb(1);
            const data = toolbox.os_allocate_memory(num_bytes);
            toolbox.expecteq(num_bytes, data.len, "Wrong number of bytes allocated");
            toolbox.expect(
                toolbox.is_aligned_to(@intFromPtr(data.ptr), toolbox.PAGE_SIZE),
                "System allocated memory should be page aligned",
                .{},
            );
            //os allocator should returned zero'ed memory
            for (data) |b| toolbox.expecteq(b, 0, "Memory should be zeroed from system allocator");

            for (data) |*b| b.* = 0xFF;
            toolbox.os_free_memory(data);
        }

        const arena_size = toolbox.mb(1);
        var test_arena = toolbox.Arena.init(arena_size);
        //test init arena
        {
            toolbox.expecteq(0, test_arena.pos, "Arena should have initial postion of 0");
            toolbox.expecteq(arena_size - @sizeOf(toolbox.Arena) - @sizeOf(std.mem.Allocator.VTable), test_arena.data.len, "Wrong arena capacity");
        }

        //test push_bytes_unaligned
        const num_bytes = toolbox.kb(4);
        {
            const bytes = test_arena.push_bytes_unaligned(num_bytes);
            toolbox.expecteq(num_bytes, bytes.len, "Wrong number of bytes allocated");

            for (bytes) |*b| b.* = 0xFF;
        }
        //test push_slice
        const num_ints = 1024;
        {
            const ints = test_arena.push_slice(u32, num_ints);
            toolbox.expecteq(num_ints, ints.len, "Wrong number of longs");

            for (ints) |*b| b.* = 0xFFFF_FFFF;
        }
        //test total_bytes_used and reset
        {
            toolbox.expecteq(num_ints * 4 + num_bytes, test_arena.total_bytes_used(), "Failed 'test total_bytes_used and reset': Wrong number of bytes used");
            test_arena.reset();
            toolbox.expecteq(0, test_arena.total_bytes_used(), "Arena should be reset");
        }
        //test push_bytes_z
        {
            const TEST_LEN = 20;
            const bytes_z = test_arena.push_bytes_z(TEST_LEN);
            @memset(bytes_z, 0xAA);
            const C = struct {
                extern fn strlen(string: [*c]u8) c_int;
            };
            const len = C.strlen(bytes_z.ptr);
            toolbox.expecteq(TEST_LEN, bytes_z.len, "Unexpected len for push_bytes_z");
            toolbox.expecteq(TEST_LEN, len, "Unexpected strlen result for push_bytes_z");
            test_arena.reset();
        }
        //test save points
        {
            const ints = test_arena.push_slice(u32, num_ints);
            toolbox.expecteq(num_ints * 4, test_arena.total_bytes_used(), "Wrong number of bytes used");
            toolbox.expecteq(num_ints, ints.len, "Wrong number of longs");
            const save_point = test_arena.create_save_point();
            defer {
                test_arena.restore_save_point(save_point);
                toolbox.expecteq(num_ints * 4, test_arena.total_bytes_used(), "Wrong number of bytes used after restoring save point");
            }
            const ints2 = test_arena.push_slice(u32, num_ints);
            toolbox.expecteq(num_ints * 4 * 2, test_arena.total_bytes_used(), "Wrong number of bytes used");
            toolbox.expecteq(num_ints, ints2.len, "Wrong number of longs used");
        }
        //test scratch arena
        {
            const scratch_arena_0 = toolbox.get_scratch_arena(null);

            defer {
                const src_str = "12345678";
                const dest_str = scratch_arena_0.push_slice(u8, src_str.len);
                @memcpy(dest_str, src_str);
                toolbox.expect(
                    std.mem.eql(u8, dest_str, src_str),
                    "scratch arena not working with basic copy",
                    .{},
                );
                scratch_arena_0.restore();
            }
            {
                const src_str = "12345678";
                const dest_str = scratch_arena_0.push_slice(u8, src_str.len);
                @memcpy(dest_str, src_str);
                toolbox.expect(
                    std.mem.eql(u8, dest_str, src_str),
                    "scratch arena not working with basic copy",
                    .{},
                );
            }
            {
                const scratch_arena_1 = toolbox.get_scratch_arena(scratch_arena_0);
                defer {
                    const src_str = "abcdefg";
                    const dest_str = scratch_arena_1.push_slice(u8, src_str.len);
                    @memcpy(dest_str, src_str);
                    toolbox.expect(
                        std.mem.eql(u8, dest_str, src_str),
                        "scratch arena not working with basic copy",
                        .{},
                    );
                    scratch_arena_1.restore();
                }
                {
                    const src_str = "abcdefg";
                    const dest_str = scratch_arena_1.push_slice(u8, src_str.len);
                    @memcpy(dest_str, src_str);
                    toolbox.expect(
                        std.mem.eql(u8, dest_str, src_str),
                        "scratch arena not working with basic copy",
                        .{},
                    );
                }
                const scratch_arena_0a = toolbox.get_scratch_arena(scratch_arena_1);
                defer scratch_arena_0a.restore();
                {
                    const src_str = "こんにちは!";
                    const dest_str = scratch_arena_0a.push_slice(u8, src_str.len);
                    @memcpy(dest_str, src_str);
                    toolbox.expect(
                        std.mem.eql(u8, dest_str, src_str),
                        "scratch arena not working with basic copy",
                        .{},
                    );
                }
            }
        }
        //pool allocator
        {
            const POOL_SIZE = 8;
            var pool_allocator = toolbox.PoolAllocator(i32).init(POOL_SIZE, test_arena);
            var ptrs: [POOL_SIZE * 2]*i32 = undefined;
            {
                var i: usize = 0;
                while (i < POOL_SIZE) : (i += 1) {
                    ptrs[i] = pool_allocator.alloc();
                }
            }
            {
                pool_allocator.free(ptrs[3]);
                ptrs[3] = pool_allocator.alloc();

                pool_allocator.free(ptrs[7]);
                pool_allocator.free(ptrs[6]);
                ptrs[6] = pool_allocator.alloc();
                ptrs[7] = pool_allocator.alloc();
            }
        }

        test_arena.free_all();
    }

    //Random removal Linked list
    {
        defer arena.reset();
        const IntNode = struct {
            value: i64,
            next: ?*@This() = null,
            prev: ?*@This() = null,
        };
        var free_list: ?*IntNode = null;
        var list = toolbox.RandomRemovalLinkedList(IntNode){};
        const first_element = list.append_value(.{ .value = 42 }, arena, &free_list);
        toolbox.expect(list.len == 1, "List should be length 1", .{});
        toolbox.expect(first_element.value == 42, "Node should have a value of 42", .{});
        toolbox.expect(list.head.? == first_element, "List head should be the same as the first node", .{});
        toolbox.expect(list.tail.? == first_element, "List tail should be the same as its only node", .{});

        const second_element = list.append_value(.{ .value = 42 * 2 }, arena, &free_list);
        const third_element = list.append_value(.{ .value = 42 * 3 }, arena, &free_list);

        toolbox.expect(list.len == 3, "List should be length 3", .{});
        toolbox.expect(second_element.value == 42 * 2, "Second element is wrong value", .{});
        toolbox.expect(third_element.value == 42 * 3, "Third element is wrong value", .{});
        toolbox.expect(list.head.? == first_element, "List head should be the same as the first node", .{});

        toolbox.expecteq(null, free_list, "Free list should be empty!");
        {
            var i: i64 = 1;
            var it = list.iterator();
            while (it.next()) |node| {
                toolbox.expect(
                    node.value == 42 * i,
                    "Value for linked list node is wrong. Expected: {}, Actual: {} ",
                    .{ 42 * i, node.value },
                );
                if (node == second_element) {
                    list.remove(node, &free_list);
                }
                i += 1;
            }
        }

        toolbox.expect(list.len == 2, "List should be length 2", .{});
        toolbox.expect(free_list != null, "Free list should be not empty!", .{});
        {
            var i: i64 = 1;
            var it = list.iterator();
            while (it.next()) |node| {
                toolbox.expect(
                    node.value == 42 * i,
                    "Value for linked list node is wrong. Expected: {}, Actual: {} ",
                    .{ 42 * i, node.value },
                );
                i += 2;
            }
        }

        const zeroth_element = list.prepend_value(
            .{ .value = 42 * 0 },
            arena,
            &free_list,
        );
        toolbox.expecteq(null, free_list, "Free list should be empty!");
        toolbox.expect(list.len == 3, "List should be length 3", .{});
        toolbox.expect(zeroth_element.value == 42 * 0, "0th element is wrong value", .{});
        {
            var i: i64 = 0;
            var it = list.iterator();
            while (it.next()) |node| {
                toolbox.expect(
                    node.value == 42 * i,
                    "Value for linked list node is wrong. Expected: {}, Actual: {} ",
                    .{ 42 * i, node.value },
                );
                i += 1;
                if (i == 2) {
                    i = 3;
                }
            }
        }

        //removing nodes...
        {
            toolbox.expect(list.tail == third_element, "List tail is wrong", .{});
            list.remove(third_element, &free_list);
            toolbox.expect(list.len == 2, "List should be length 2", .{});
            toolbox.expect(list.tail == first_element, "List tail is wrong", .{});
            toolbox.expect(list.head == zeroth_element, "List head is wrong", .{});
            list.remove(zeroth_element, &free_list);
            toolbox.expect(list.tail == first_element, "List tail is wrong", .{});
            toolbox.expect(list.head == first_element, "List head is wrong", .{});
            toolbox.expect(list.len == 1, "List should be length 1", .{});
            list.remove(first_element, &free_list);
            toolbox.expect(list.len == 0, "List should be length 1", .{});
            toolbox.expect(list.head == null, "List head should be null", .{});
            toolbox.expect(list.tail == null, "List tail should be null", .{});
        }
    }

    //Hash map
    {
        defer arena.reset();
        var map = toolbox.HashMap([]const u8, i64){};
        map.put("Macs", 123, arena);
        map.put("Apple IIs", 432, arena);
        map.put("PCs", 8765, arena);

        var data = map.get("Blah");
        toolbox.expecteq(null, data, "Hash map retrieval is wrong!");
        data = map.get("Macs");
        toolbox.expecteq(123, data.?, "Hash map retrieval is wrong!");
        data = map.get("Apple IIs");
        toolbox.expecteq(432, data.?, "Hash map retrieval is wrong!");
        data = map.get("PCs");
        toolbox.expecteq(8765, data.?, "Hash map retrieval is wrong!");

        map.put("PCs", 87654, arena);
        data = map.get("PCs");
        toolbox.expect(data.? == 87654, "Hash map retrieval is wrong! Expected: {}, Got: {any}", .{ 87654, data });

        toolbox.expect(map.len == 3, "Hash map len is wrong! Expected: {}, Got: {}", .{ 3, map.len });
        toolbox.expect(
            map.cap == toolbox.INITIAL_HASH_MAP_CAPACITY,
            "Hash map capacity is wrong! Expected: {}, Got: {}",
            .{ toolbox.INITIAL_HASH_MAP_CAPACITY, map.cap },
        );
        map.remove("PCs");
        data = map.get("PCs");
        toolbox.expecteq(null, data, "Hash map retrieval is wrong!");
        toolbox.expecteq(2, map.len, "Hash map len is wrong!");

        data = map.get("Garbage");
        toolbox.expecteq(null, data, "Hash map retrieval is wrong!");

        //collision keys
        map.put("GReLUrM4wMqfg9yzV3KQ", 654, arena);
        map.put("8yn0iYCKYHlIj4-BwPqk", 234, arena);
        data = map.get("GReLUrM4wMqfg9yzV3KQ");
        toolbox.expecteq(654, data.?, "Hash map retrieval is wrong!");
        data = map.get("8yn0iYCKYHlIj4-BwPqk");
        toolbox.expecteq(234, data.?, "Hash map retrieval is wrong!");

        //NOTE Apple IIs, GReLUrM4wMqfg9yzV3KQ, and  8yn0iYCKYHlIj4-BwPqk  collide in this example
        map.remove("Apple IIs");
        toolbox.expecteq(3, map.len, "Hash map len is wrong!");
        data = map.get("GReLUrM4wMqfg9yzV3KQ");
        toolbox.expecteq(654, data.?, "Hash map retrieval is wrong!");
        data = map.get("8yn0iYCKYHlIj4-BwPqk");
        toolbox.expecteq(234, data.?, "Hash map retrieval is wrong!");

        //TODO: fix this crap!!
        map.remove("GReLUrM4wMqfg9yzV3KQ");
        toolbox.expecteq(2, map.len, "Hash map len is wrong!");
        data = map.get("GReLUrM4wMqfg9yzV3KQ");
        toolbox.expecteq(null, data, "Hash map retrieval is wrong!");
        data = map.get("8yn0iYCKYHlIj4-BwPqk");
        toolbox.expecteq(234, data.?, "Hash map retrieval is wrong!");

        map.remove("8yn0iYCKYHlIj4-BwPqk");
        toolbox.expecteq(1, map.len, "Hash map len is wrong!");
        data = map.get("8yn0iYCKYHlIj4-BwPqk");
        toolbox.expecteq(null, data, "Hash map retrieval is wrong!");
    }

    boksos_collision_removal_bug(arena);

    //numerial hashmap
    {
        defer arena.reset();

        var map = toolbox.HashMap(i64, i64){};
        map.put(123, 123, arena);
        map.put(432, 432, arena);
        map.put(456, 8765, arena);

        var data = map.get(543);
        toolbox.expecteq(null, data, "Hash map retrieval is wrong!");
        data = map.get(123);
        toolbox.expecteq(123, data.?, "Hash map retrieval is wrong!");
        data = map.get(432);
        toolbox.expecteq(432, data.?, "Hash map retrieval is wrong!");
        data = map.get(456);
        toolbox.expecteq(8765, data.?, "Hash map retrieval is wrong!");
    }
    //numerial hashmap
    {
        defer arena.reset();
        var keys = [_]i64{ 123, 432, 456, 6543 };

        var map = toolbox.HashMap(*const i64, i64){};
        map.put(&keys[0], 123, arena);
        map.put(&keys[1], 432, arena);
        map.put(&keys[2], 8765, arena);

        keys[0] = 0;
        keys[1] = 0;
        keys[2] = 0;

        var data = map.get(&keys[3]);
        toolbox.expecteq(null, data, "Hash map retrieval is wrong!");
        data = map.get(&keys[0]);
        toolbox.expecteq(123, data.?, "Hash map retrieval is wrong!");
        data = map.get(&keys[1]);
        toolbox.expecteq(432, data.?, "Hash map retrieval is wrong!");
        data = map.get(&keys[2]);
        toolbox.expecteq(8765, data.?, "Hash map retrieval is wrong!");
    }
    //string
    {
        const english = toolbox.str8lit("Hello!");
        const korean = toolbox.str8lit("안녕하세요!");
        const japanese = toolbox.str8lit("こんにちは!");

        const buffer = [_:0]u8{ 'H', 'e', 'l', 'l', 'o', '!', 0 };
        const runtime_english = toolbox.str8(buffer[0..]);
        toolbox.expecteq(6, english.rune_length(), "Wrong rune length");
        toolbox.expecteq(6, runtime_english.rune_length(), "Wrong rune length");
        toolbox.expecteq(6, korean.rune_length(), "Wrong rune length");
        toolbox.expecteq(6, japanese.rune_length(), "Wrong rune length");

        {
            var it = japanese.iterator();
            var i: usize = 0;
            while (it.next()) |rune_and_length| {
                const rune = rune_and_length.rune;
                const expected: toolbox.Rune = switch (i) {
                    0 => 'こ',
                    1 => 'ん',
                    2 => 'に',
                    3 => 'ち',
                    4 => 'は',
                    5 => '!',
                    else => toolbox.panic("Wrong number of runes!", .{}),
                };
                i += 1;
                toolbox.expecteq(expected, rune, "Wrong rune!");
            }
        }

        //substring
        {
            const s = toolbox.str8lit("hello!");
            const ss = s.substring(1, 3, arena);
            toolbox.expecteq(2, ss.rune_length(), "Wrong rune length");
            toolbox.expecteq(2, ss.bytes.len, "Wrong byte length");
            toolbox.expecteq(ss.bytes[0], 'e', "Wrong char at index 0");
            toolbox.expecteq(ss.bytes[1], 'l', "Wrong char at index 1");
        }

        //contains
        {
            const s = toolbox.str8lit("hello!");
            const substring = toolbox.str8lit("ll");
            const not_substring1 = toolbox.str8lit("ll!");
            const not_substring2 = toolbox.str8lit("hello!!!!");

            toolbox.expecteq(s.contains(substring), true, "Should contain");
            toolbox.expecteq(s.contains(not_substring1), false, "Should not contain");
            toolbox.expecteq(s.contains(not_substring2), false, "Should not contain");
        }

        //copy
        {
            defer arena.reset();
            const s = toolbox.str8lit("hello!");
            const copy = s.copy(arena);
            toolbox.expect(
                copy.bytes.ptr != s.bytes.ptr,
                "String copy and string ptrs should not be the same!",
                .{},
            );
            toolbox.expect(
                std.mem.eql(u8, copy.bytes, s.bytes),
                "String copy and string should be the same!",
                .{},
            );
        }
    }
    //string builder
    {
        defer arena.reset();
        var sb = toolbox.StringBuilder{};
        sb.append_fmt("Hello! {}\n", .{123}, arena);
        sb.append_fmt("こんにちは!! {}", .{123}, arena);
        const str = sb.str8(arena);
        const expected = toolbox.str8lit("Hello! 123\nこんにちは!! 123");

        toolbox.expect(
            std.mem.eql(u8, str.bytes, expected.bytes),
            "String builder bytes incorrect!",
            .{},
        );
        toolbox.expecteq(
            str.rune_length(),
            expected.rune_length(),
            "String builder rune lengths incorrect!",
        );
    }
    //stack
    //TODO
    {}
    //TODO: replace with channel
    //ring queue
    {
        defer arena.reset();
        const desired_cap = 1024;
        var q = toolbox.make_not_magic_ring_queue(u64, desired_cap, arena);
        defer toolbox.free_not_magic_ring_queue(q);
        toolbox.expect(
            q.cap() >= desired_cap,
            "Unexpected magic ring queue capacity {}. Expected at least {}",
            .{ q.cap(), desired_cap },
        );
        var n: usize = 3;
        var total_items: u64 = 0;
        while (total_items < q.cap() * 2) {
            const in = arena.push_slice(u64, n);
            for (in, 0..) |*d, i| d.* = i;
            q.enqueue(in);
            toolbox.expecteq(
                in.len,
                q.len(),
                "Bad value from q.slots_used()",
            );

            const out_buffer = arena.push_slice(u64, n);
            const out = q.dequeue(out_buffer);
            toolbox.expecteq(
                in.len,
                out.len,
                "Should have dequeued the expected amount",
            );
            for (out, 0..) |x, i| {
                toolbox.expecteq(i, x, "unexpected value dequed");
            }
            toolbox.expecteq(
                0,
                q.len(),
                "Bad value from q.len()",
            );
            total_items += n;

            n *= 2;
            n = @min(q.cap() - q.len(), n);
        }
    }
    //magic ring queue
    if (comptime toolbox.THIS_HARDWARE != .WASM32) {
        defer arena.reset();
        const desired_cap = 1024;
        var q = toolbox.make_magic_ring_queue(u64, desired_cap, arena);
        defer toolbox.free_magic_ring_queue(q);
        toolbox.expect(
            q.cap() >= desired_cap,
            "Unexpected magic ring queue capacity {}. Expected at least {}",
            .{ q.cap(), desired_cap },
        );
        var n: usize = 3;
        var total_items: u64 = 0;
        while (total_items < q.cap() * 2) {
            const in = arena.push_slice(u64, n);
            for (in, 0..) |*d, i| d.* = i;
            q.enqueue(in);
            toolbox.expecteq(
                in.len,
                q.len(),
                "Bad value from q.slots_used()",
            );

            const out_buffer = arena.push_slice(u64, n);
            const out = q.dequeue(out_buffer);
            toolbox.expecteq(
                in.len,
                out.len,
                "Should have dequeued the expected amount",
            );
            for (out, 0..) |x, i| {
                toolbox.expecteq(i, x, "unexpected value dequed");
            }
            toolbox.expecteq(
                0,
                q.len(),
                "Bad value from q.len()",
            );
            total_items += n;

            n *= 2;
            n = @min(q.cap() - q.len(), n);
        }
    }
    //concurrent ring queue single thread test
    {
        defer arena.reset();
        var ring_queue = toolbox.MultiProducerMultiConsumerRingQueue(i64).init(8, arena);
        for (0..10) |u| {
            const i = @as(i64, @intCast(u));
            ring_queue.force_enqueue(i);
        }
        var expected: i64 = 3;
        while (ring_queue.dequeue()) |got| {
            toolbox.expect(
                expected == got,
                "Unexpected ring queue value.  Expected: {}, Got: {}",
                .{ expected, got },
            );
            expected += 1;
        }
    }
    //MultiProducerMultiConsumerRingQueue multi thread test
    //TODO: remove for now
    if (comptime toolbox.THIS_HARDWARE != .WASM32) {
        defer arena.reset();

        const TestData = struct {
            n: i64,
            thread_id: usize,
        };
        const NUM_PRODUCERS = 3;
        const NUM_CONSUMERS = 10;
        const MAX_VALUE_DEQUEUED = 0xFFFF;

        var producers_running: isize = 0;
        var producers: [NUM_PRODUCERS]std.Thread = undefined;
        var consumers: [NUM_CONSUMERS]std.Thread = undefined;
        var max_value_dequeued = [_]i64{0} ** NUM_PRODUCERS;
        var ring_queue =
            toolbox.MultiProducerMultiConsumerRingQueue(TestData).init(64, arena);

        for (&producers, 0..) |*p, i| {
            producers_running += 1;
            p.* = try std.Thread.spawn(.{}, concurrent_queue_enqueue_test_loop, .{
                &ring_queue,
                &producers_running,
                i,
                MAX_VALUE_DEQUEUED,
            });
        }
        for (&consumers) |*c| {
            c.* = try std.Thread.spawn(.{}, concurrent_queue_dequeue_test_loop, .{
                &ring_queue,
                &producers_running,
                &max_value_dequeued,
                NUM_PRODUCERS,
            });
        }

        for (producers) |p| {
            p.join();
        }
        for (consumers) |c| {
            c.join();
        }
        for (max_value_dequeued, 0..) |n, i| {
            toolbox.expect(
                n == MAX_VALUE_DEQUEUED,
                "Expected max value dequeued to be for thread {}: {X}, but was {X} ",
                .{ i, MAX_VALUE_DEQUEUED, n },
            );
        }
    }
    //dynamic array number
    {
        var da = toolbox.DynamicArray(i64){};
        da.append(3, arena);
        da.append(2, arena);
        da.append(1, arena);
        da.append(4, arena);
        toolbox.assert(da.len == 4, "Unexpected dynamic array length: {}", .{da.len});
        toolbox.assert(da.cap == toolbox.DYNAMIC_ARRAY_INITIAL_CAPACITY, "Unexpected dynamic array capacity: {}", .{da.len});
        toolbox.println("Dynamic array print: {}", .{da});
        for (da.items(), [_]i64{ 3, 2, 1, 4 }) |actual, expected| {
            toolbox.expecteq(expected, actual, "Incorrect value from dynamic array");
        }
        da.sort();
        for (da.items(), [_]i64{ 1, 2, 3, 4 }) |actual, expected| {
            toolbox.expecteq(expected, actual, "Incorrect value from dynamic array");
        }
    }
    //dynamic array pointer to struct
    {
        const TestStruct = struct {
            num: i64,
        };
        var da = toolbox.DynamicArray(*TestStruct){};
        var val = arena.push(TestStruct);
        val.num = 3;
        da.append(val, arena);
        val = arena.push(TestStruct);
        val.num = 2;
        da.append(val, arena);
        val = arena.push(TestStruct);
        val.num = 1;
        da.append(val, arena);
        val = arena.push(TestStruct);
        val.num = 4;
        da.append(val, arena);
        toolbox.assert(da.len == 4, "Unexpected dynamic array length: {}", .{da.len});
        toolbox.assert(da.cap == toolbox.DYNAMIC_ARRAY_INITIAL_CAPACITY, "Unexpected dynamic array capacity: {}", .{da.len});
        toolbox.println("Dynamic array print: {}", .{da});
        for (da.items(), [_]i64{ 3, 2, 1, 4 }) |actual, expected| {
            toolbox.expecteq(expected, actual.num, "Incorrect value from dynamic array");
        }
        da.sort("num");
        for (da.items(), [_]i64{ 1, 2, 3, 4 }) |actual, expected| {
            toolbox.expecteq(expected, actual.num, "Incorrect value from dynamic array");
        }
    }
    //fibers
    if (comptime toolbox.THIS_HARDWARE != .WASM32) {
        const FiberTestFn = struct {
            fn fiber_test(til: *usize) void {
                for (1..til.*) |i| {
                    toolbox.println("Fiber output {}", .{i});
                    fiber.yield();
                }
            }
        };
        defer arena.reset();
        var til: usize = 10;
        fiber.init(arena, 4, toolbox.kb(64));
        fiber.go(FiberTestFn.fiber_test, .{&til}, arena);
        fiber.go(FiberTestFn.fiber_test, .{&til}, arena);
        while (fiber.number_of_fibers_active() > 1) {
            fiber.yield();
        }
    }
    //struct formatter
    {
        const S = struct {
            a: usize = 0x1234,
            b: []const u8 = "Hello!",

            pub const format = toolbox.format_struct;
        };
        toolbox.println("Struct formatter hex: {X}", .{S{}});
        toolbox.println("Struct formatter decimal: {}", .{S{}});
    }
    //profiler
    {
        profiler.start_profiler();
        defer {
            profiler.end_profiler();
            const stats = profiler.compute_statistics_of_current_state(arena);
            toolbox.println("Total time: {}ms", .{stats.total_elapsed.milliseconds()});
            for (stats.section_statistics.items()) |stat| {
                toolbox.expect(
                    stat.max_time_elapsed_with_children.ticks >= stat.min_time_elapsed_with_children.ticks,
                    "Max time elapsed: {}mcs < Min time elapsed: {}mcs",
                    .{ stat.max_time_elapsed_with_children.ticks, stat.min_time_elapsed_with_children.ticks },
                );
                toolbox.expect(
                    stat.time_elapsed_with_children.ticks >= stat.time_elapsed_without_children.ticks,
                    "Time elapsed with children: {}mcs < time elapsed without children: {}mcs",
                    .{ stat.time_elapsed_with_children.ticks, stat.time_elapsed_without_children.ticks },
                );
                toolbox.expect(
                    stat.time_elapsed_with_children.ticks >= stat.max_time_elapsed_with_children.ticks,
                    "Max time elapsed without children: {}mcs >= total time elapsed without children: {}mcs",
                    .{ stat.max_time_elapsed_with_children.ticks, stat.time_elapsed_without_children.ticks },
                );
                toolbox.expect(
                    stat.time_elapsed_with_children.ticks >= stat.min_time_elapsed_with_children.ticks,
                    "Min time elapsed without children: {}mcs >= total time elapsed with children: {}mcs",
                    .{ stat.min_time_elapsed_with_children.ticks, stat.time_elapsed_without_children.ticks },
                );
                toolbox.expect(
                    stat.time_elapsed_with_children.ticks >= 0,
                    "Time elapsed with children was negative: {}mcs",
                    .{stat.time_elapsed_with_children.ticks},
                );
                toolbox.expect(
                    stat.time_elapsed_without_children.ticks >= 0,
                    "Time elapsed without children was negative: {}mcs",
                    .{stat.time_elapsed_without_children.ticks},
                );
                toolbox.expect(
                    stat.max_time_elapsed_with_children.ticks >= 0,
                    "Max time elapsed without children was negative: {}mcs",
                    .{stat.max_time_elapsed_with_children.ticks},
                );
                toolbox.expect(
                    stat.min_time_elapsed_with_children.ticks >= 0,
                    "Min time elapsed without children was negative: {}mcs",
                    .{stat.min_time_elapsed_with_children.ticks},
                );
                toolbox.println_str8(stat.str8(arena));
            }
        }

        profiler.begin("Parent Section");
        for (0..10000) |_| {
            profiler.begin("Nested");
            asm volatile (
                \\nop
                \\nop
                \\nop
                \\nop
                \\nop
            );
            profiler.end();
        }
        profiler_fn1(20);
        profiler.end();
    }
    toolbox.println("\nAll tests passed!", .{});
}

//Collision removal bug found in BoksOS
fn boksos_collision_removal_bug(arena: *toolbox.Arena) void {
    defer arena.reset();
    var map = toolbox.HashMap(u16, u16){};
    const n = 128;
    for (0..n) |i| {
        const kv: u16 = @intCast(i);
        map.put(kv, kv, arena);
        toolbox.expect(map.get(kv) != null, "Key {} should be in map!", .{kv});
        toolbox.expecteq(kv, map.get(kv), "Map value incorrect!");
        toolbox.expecteq(i + 1, map.len, "Map len incorrect!");
    }
    for (0..n) |i| {
        const outer_kv: u16 = @intCast(i);
        map.remove(outer_kv);
        //TODO: fix
        toolbox.expecteq(n - i - 1, map.len, "Map len incorrect!");
        toolbox.expecteq(null, map.get(outer_kv), "Map key should be removed!");
        for (i + 1..n) |j| {
            const inner_kv: u16 = @intCast(j);
            //Bug found in NVMe map in BoksOS
            //TODO: fix
            toolbox.expecteq(inner_kv, map.get(inner_kv), "Map value incorrect!");
        }
    }
}
fn profiler_fn1(n: isize) void {
    profiler.begin("Fn1");
    defer profiler.end();
    if (n <= 0) {
        return;
    }
    asm volatile (
        \\nop
        \\nop
        \\nop
        \\nop
        \\nop
    );
    profiler_fn2(n);
}
fn profiler_fn2(n: isize) void {
    profiler.begin("Fn2");
    defer profiler.end();

    profiler_fn1(n - 1);
    for (0..10000) |_| {
        asm volatile (
            \\nop
            \\nop
            \\nop
            \\nop
            \\nop
        );
    }
}
fn concurrent_queue_enqueue_test_loop(
    ring_queue: anytype,
    producers_running: *isize,
    thread_id: usize,
    comptime max_value: i64,
) void {
    for (0..max_value + 1) |n| {
        while (!ring_queue.enqueue(.{ .n = @intCast(n), .thread_id = thread_id })) {
            std.atomic.spinLoopHint();
        }
    }
    _ = @atomicRmw(isize, producers_running, .Sub, 1, .monotonic);
}
fn concurrent_queue_dequeue_test_loop(
    ring_queue: anytype,
    producers_running: *isize,
    max_value_dequeued: []i64,
    comptime num_producers: usize,
) void {
    var last_actual = [_]i64{-1} ** num_producers;

    var data_left = true;
    while (@atomicLoad(isize, producers_running, .monotonic) > 0 or
        data_left)
    {
        if (ring_queue.dequeue()) |test_data| {
            data_left = true;
            const thread_id: usize = test_data.thread_id;
            const actual = test_data.n;

            toolbox.expect(
                actual > last_actual[thread_id],
                \\Unexpected ring queue value.  Expected greater than: {}, Was: {}, Thread: {}
                \\ rcursor: {}, wcursor: {} 
            ,
                .{
                    last_actual[thread_id] & 0xFFFF_FFFF, actual & 0xFFFF_FFFF, thread_id,
                    ring_queue.rcursor,                   ring_queue.wcursor,
                },
            );
            last_actual[thread_id] = actual;
            _ = @atomicRmw(i64, &max_value_dequeued[thread_id], .Max, actual, .acq_rel);
        } else {
            data_left = false;

            std.atomic.spinLoopHint();
        }
    }
}

fn run_benchmarks() void {
    var arena = toolbox.Arena.init(toolbox.mb(16));
    profiler.start_profiler();
    defer {
        profiler.end_profiler();
        const stats = profiler.compute_statistics_of_current_state(arena);
        toolbox.println("Total time: {}ms", .{stats.total_elapsed.milliseconds()});
        for (stats.section_statistics.items()) |to_print| {
            toolbox.println_str8(to_print.str8(arena));
        }
        arena.free_all();
    }

    benchmark("is_iterable", IterableBenchmark{}, arena);
    benchmark("allocate, touch and free memory with OS allocator", OSAllocateBenchmark{}, arena);

    {
        const save_point = arena.create_save_point();
        defer arena.restore_save_point(save_point);
        const new_arena = arena.create_arena_from_arena(toolbox.mb(8));
        var arena_benchmark = ArenaAllocateBenchmark{};
        benchmark("allocate, touch and free memory with arena", &arena_benchmark, new_arena);
        // arena.reset();
    }

    //hash map
    {
        {
            var zhmb = ZigHashMapBenchmark{};
            zhmb.map.ensureUnusedCapacity(512) catch |e| {
                toolbox.panic("ensureUnusedCapacity failed: {}", .{e});
            };
            benchmark("Zig HashMap", &zhmb, arena);
            var thmb = ToolboxHashMapBenchmark.init(arena);
            benchmark("Toolbox HashMap", &thmb, arena);
        }

        {
            var zihmb = ZigIntHashMapBenchmark{};
            zihmb.map.ensureUnusedCapacity(512) catch |e| {
                toolbox.panic("ensureUnusedCapacity failed: {}", .{e});
            };
            benchmark("Zig IntHashMap", &zihmb, arena);
            var thimb = ToolboxIntHashMapBenchmark.init(arena);
            benchmark("Toolbox IntHashMap", &thimb, arena);
        }

        {
            var thb = ToolboxHashBenchmark{};
            benchmark("Toolbox Hash", &thb, arena);
            toolbox.println("last hash {x}", .{thb.last_hash});
        }
    }
}

const LinkedListQueuePushBenchmark = struct {
    list: *toolbox.LinkedListQueue(i64),
    fn benchmark(self: *LinkedListQueuePushBenchmark, _: *toolbox.Arena) void {
        _ = self.list.push(2);
    }
};
const LinkedListQueuePopBenchmark = struct {
    list: *toolbox.LinkedListQueue(i64),
    fn benchmark(self: *LinkedListQueuePopBenchmark, _: *toolbox.Arena) void {
        _ = self.list.pop();
    }
};
const LinkedListStackPopBenchmark = struct {
    list: *toolbox.LinkedListStack(i64),
    fn benchmark(self: *LinkedListStackPopBenchmark, _: *toolbox.Arena) void {
        _ = self.list.pop();
    }
};
const LinkedListStackPushBenchmark = struct {
    list: *toolbox.LinkedListStack(i64),
    fn benchmark(self: *LinkedListStackPushBenchmark, _: *toolbox.Arena) void {
        _ = self.list.push(20);
    }
};
const IterableBenchmark = struct {
    fn benchmark(_: *const IterableBenchmark, _: *toolbox.Arena) void {
        _ = toolbox.is_iterable("This is iterable!");
    }
};
const OSAllocateBenchmark = struct {
    fn benchmark(_: *const OSAllocateBenchmark, _: *toolbox.Arena) void {
        const memory = toolbox.os_allocate_memory(toolbox.mb(4));
        memory[0x135] = 0xFF;
        toolbox.os_free_memory(memory);
    }
};
const ArenaAllocateBenchmark = struct {
    fn benchmark(_: *ArenaAllocateBenchmark, arena: *toolbox.Arena) void {
        const memory = arena.push_slice(u8, toolbox.mb(4));
        memory[0x135] = 0xFF;
        arena.reset();
    }
};
const ZigHashMapBenchmark = struct {
    map: std.StringHashMap(i64) = std.StringHashMap(i64).init(std.heap.page_allocator),

    fn benchmark(self: *ZigHashMapBenchmark, _: *toolbox.Arena) void {
        const kv = .{
            "hello",                12345,
            "yes",                  6543,
            "no",                   98765,
            "burger",               7654,
            "test",                 345,
            "GReLUrM4wMqfg9yzV3KQ", 6543,
            "8yn0iYCKYHlIj4-BwPqk", 4567,
        };
        comptime var i = 0;
        inline while (i < kv.len) : (i += 2) {
            const key: []const u8 = kv[i];
            var v = self.map.get(key) orelse kv[i + 1];
            v += 1;
            self.map.put(key, v) catch |e| {
                toolbox.panic("Error putting into map: {}", .{e});
            };
        }
    }
};
const ToolboxHashMapBenchmark = struct {
    map: toolbox.HashMap(toolbox.String8, i64),

    fn init(arena: *toolbox.Arena) ToolboxHashMapBenchmark {
        var map = toolbox.HashMap(toolbox.String8, i64){};
        map.expand(512, arena);
        return ToolboxHashMapBenchmark{
            .map = map,
        };
    }

    const s8 = toolbox.str8lit;
    fn benchmark(self: *ToolboxHashMapBenchmark, arena: *toolbox.Arena) void {
        const kv = .{
            s8("hello"),                12345,
            s8("yes"),                  6543,
            s8("no"),                   98765,
            s8("burger"),               7654,
            s8("test"),                 345,
            s8("GReLUrM4wMqfg9yzV3KQ"), 6543,
            s8("8yn0iYCKYHlIj4-BwPqk"), 4567,
        };
        comptime var i = 0;
        inline while (i < kv.len) : (i += 2) {
            const key = kv[i];
            var v = self.map.get(key) orelse kv[i + 1];
            v += 1;
            self.map.put(key, v, arena);
        }
    }
};
const ZigIntHashMapBenchmark = struct {
    map: std.AutoHashMap(i64, i64) = std.AutoHashMap(i64, i64).init(std.heap.page_allocator),

    fn benchmark(self: *ZigIntHashMapBenchmark, _: *toolbox.Arena) void {
        const kv = .{
            543232,   12345,
            68495,    6543,
            76453423, 98765,
            1234567,  7654,
            76543,    345,
            49309428, 6543,
        };
        comptime var i = 0;
        inline while (i < kv.len) : (i += 2) {
            const key = kv[i];
            var v = self.map.get(key) orelse kv[i + 1];
            v += 1;
            self.map.put(key, v) catch |e| {
                toolbox.panic("Error putting into map: {}", .{e});
            };
        }
    }
};
const ToolboxIntHashMapBenchmark = struct {
    map: toolbox.HashMap(i64, i64),

    fn init(arena: *toolbox.Arena) ToolboxIntHashMapBenchmark {
        var map = toolbox.HashMap(i64, i64){};
        map.expand(512, arena);
        return ToolboxIntHashMapBenchmark{
            .map = map,
        };
    }
    fn benchmark(self: *ToolboxIntHashMapBenchmark, arena: *toolbox.Arena) void {
        const kv = .{
            543232,   12345,
            68495,    6543,
            76453423, 98765,
            1234567,  7654,
            76543,    345,
            49309428, 6543,
        };
        comptime var i = 0;
        inline while (i < kv.len) : (i += 2) {
            const key = kv[i];
            var v = self.map.get(key) orelse kv[i + 1];
            v += 1;
            self.map.put(key, v, arena);
        }
    }
};
const ToolboxHashBenchmark = struct {
    last_hash: u64 = 0,
    fn benchmark(self: *ToolboxHashBenchmark, _: *toolbox.Arena) void {
        const k = .{
            "hello",
            "yes",
            "no",
            "burger",
            "test",
        };
        comptime var i = 0;
        inline while (i < k.len) : (i += 1) {
            self.last_hash = toolbox.hash_fnv1a64(k[i]);
        }
    }
};

pub fn benchmark(comptime benchmark_name: []const u8, benchmark_obj: anytype, arena: *toolbox.Arena) void {
    const total_iterations = 1000;
    {
        for (0..total_iterations) |_| {
            profiler.begin(benchmark_name);
            benchmark_obj.benchmark(arena);
            profiler.end();
        }
    }
}
