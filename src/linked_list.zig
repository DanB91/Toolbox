const toolbox = @import("toolbox.zig");

const CT = toolbox.ChildType;

pub fn llnext(cursor: anytype) CT(@TypeOf(cursor)) {
    if (cursor.*) |node| {
        cursor.* = node.next;
        return node;
    }
    return null;
}
pub fn llappend_value(
    list: anytype,
    value: anytype,
    arena: *toolbox.Arena,
    free_list: anytype,
) *@TypeOf(value) {
    const node = llalloc_node(@TypeOf(value), arena, free_list);
    node.* = value;
    llappend(list, node);
    return node;
}
pub fn llappend(
    list: anytype,
    node: anytype,
) void {
    if (list.tail) |t| {
        t.next = node;
    } else {
        list.head = node;
    }
    toolbox.expect(node != list.tail, "Appending node will cause cycle", .{});
    node.prev = list.tail;
    list.tail = node;
    node.next = null;

    list.len += 1;
}
pub fn llprepend_value(
    list: anytype,
    value: anytype,
    arena: *toolbox.Arena,
    free_list: anytype,
) *@TypeOf(value) {
    const node = llalloc_node(@TypeOf(value), arena, free_list);
    node.* = value;
    llprepend(list, node);
    return node;
}
pub fn llprepend(
    list: anytype,
    node: anytype,
) void {
    if (list.head == null) {
        list.tail = node;
    }
    toolbox.expect(node != list.head, "Prepending node will cause cycle", .{});
    if (list.head) |head| {
        head.prev = node;
    }
    node.next = list.head;
    list.head = node;
    node.prev = null;

    list.len += 1;
}

pub fn llremove(
    list: anytype,
    node: anytype,
    free_list: anytype,
) void {
    if (list.len == 0) {
        return;
    }
    defer {
        list.len -= 1;
        node.next = null;
        node.prev = null;
        llfree_node(node, free_list);
    }
    if (node == list.head) {
        list.head = node.next;
        if (list.head) |head| {
            head.prev = null;
        }
        if (node == list.tail) {
            toolbox.assert(list.len == 1, "If head and tail are same, then len should be 1", .{});
            list.tail = node.prev;
            if (list.tail) |tail| {
                tail.next = null;
            }
        }
        return;
    }
    if (node == list.tail) {
        list.tail = node.prev;
        if (list.tail) |tail| {
            tail.next = null;
        }
        return;
    }
    if (node.prev) |prev| {
        prev.next = node.next;
    }
    if (node.next) |next| {
        next.prev = node.prev;
    }
}

pub fn RandomRemovalLinkedList(comptime T: type) type {
    return struct {
        head: ?*T = null,
        tail: ?*T = null,
        len: usize = 0,

        const Self = @This();
        const FreeList = ?*T;
        pub const Iterator = struct {
            cursor: ?*T = null,
            pub inline fn next(self: *Iterator) ?*T {
                return llnext(&self.cursor);
            }
        };

        pub inline fn append(self: *Self, node: *T) void {
            llappend(self, node);
            self.validate();
        }
        pub inline fn append_value(self: *Self, value: T, arena: *toolbox.Arena, free_list: *FreeList) *T {
            const result = llappend_value(self, value, arena, free_list);
            self.validate();
            return result;
        }
        pub inline fn prepend(self: *Self, node: *T) void {
            llprepend(self, node);
            self.validate();
        }
        pub inline fn prepend_value(self: *Self, value: T, arena: *toolbox.Arena, free_list: *FreeList) *T {
            const result = llprepend_value(self, value, arena, free_list);
            self.validate();
            return result;
        }
        pub inline fn remove(self: *Self, node: *T, free_list: ?*FreeList) void {
            llremove(self, node, free_list);
            self.validate();
        }
        pub fn clear(self: *Self) void {
            self.* = .{};
            self.validate();
        }
        pub fn clear_and_free(self: *Self, free_list: *FreeList) void {
            var it = self.iterator();
            while (it.next()) |node| {
                llfree_node(node, free_list);
            }
            self.validate();
        }
        pub fn iterator(self: *const Self) Iterator {
            return .{
                .cursor = self.head,
            };
        }

        fn validate(self: *const Self) void {
            var count: usize = 0;
            var tortoise = self.head;
            var hare = self.head;
            while (tortoise != null and hare != null) {
                tortoise = tortoise.?.next;
                hare = hare.?.next;
                if (hare == null) {
                    break;
                }
                hare = hare.?.next;
                toolbox.expect(tortoise != hare, "Cycle in LL detected!", .{});
            }
            var it = self.iterator();
            while (it.next()) |node| {
                if (node == self.head) {
                    toolbox.expect(node.prev == null, "Head should have null prev", .{});
                } else if (node == self.tail) {
                    toolbox.expect(node.next == null, "Node should have null head", .{});
                } else {
                    toolbox.expect(node.next != null, "Middle node should have a non-null next", .{});
                    toolbox.expect(node.prev != null, "Middle node should have a non-null prev", .{});
                }
                count += 1;
            }
            toolbox.expecteq(self.len, count, "Length of LL incorrect!");
        }
    };
}

fn llalloc_node(comptime T: type, arena: *toolbox.Arena, free_list: anytype) *T {
    if (free_list.*) |node| {
        free_list.* = node.next;
        return node;
    }
    return arena.push(T);
}
fn llfree_node(node: anytype, free_list: anytype) void {
    if (free_list) |fl| {
        node.next = fl.*;
        fl.* = node;
    }
}
