const std = @import("std");
const assert = std.debug.assert;

pub const Color = packed union {
    i: u32,
    c: packed struct {
        b: u8,
        g: u8,
        r: u8,
        a: u8,
    },
};

pub const Bitmap = struct {
    width: u32,
    height: u32,
    bits: []Color,

    pub fn create(allocator: std.mem.Allocator, width: u32, height: u32) !Bitmap {
        return Bitmap{
            .width = width,
            .height = height,
            .bits = try allocator.alloc(Color, width * height),
        };
    }

    pub fn destroy(self: Bitmap, allocator: std.mem.Allocator) void {
        allocator.destroy(self.bits);
    }

    pub fn clear(self: Bitmap) void {
        for (0..self.width) |x| {
            for (0..self.height) |y| {
                self.set(.{ .x = x, .y = y }, .{ .i = 0 });
            }
        }
    }

    pub fn set(self: Bitmap, coord: Pixel, color: Color) void {
        assert(coord.x >= 0 and coord.x < self.width);
        assert(coord.y >= 0 and coord.y < self.height);

        self.bits[coord.y * self.width + coord.x] = color;
    }

    pub fn get(self: Bitmap, coord: Pixel) Color {
        assert(coord.x >= 0 and coord.x < self.width);
        assert(coord.y >= 0 and coord.y < self.height);

        return self.bits[coord.y * self.width + coord.x];
    }
};

pub const Pixel = struct {
    x: usize,
    y: usize,
};

pub const Coord = struct {
    x: i32,
    y: i32,
};

pub const WindowEventType = enum {
    mouse_drag,
    mouse_press,
    mouse_release,
};

pub const WindowEvent = union(WindowEventType) {
    mouse_drag: Coord,
    mouse_press: Coord,
    mouse_release: void,
};

pub const UiEventType = enum {
    param_update,
};

pub const UiEvent = union(UiEventType) {
    param_update: struct {
        parameter: usize,
        value: f32,
    },
};

pub fn EventQueue(comptime Event: type) type {
    return struct {
        allocator: std.mem.Allocator,
        queue: std.TailQueue(Event),
        read_only: bool,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .queue = std.TailQueue(Event){},
                .read_only = false,
            };
        }

        pub fn deinit(self: *Self) void {
            while (self.pop()) |_| {}
        }

        pub fn push(self: *Self, event: Event) void {
            assert(!self.read_only);

            var node = self.allocator.create(std.TailQueue(Event).Node) catch {
                std.log.err("Failed to allocate event!", .{});
                return;
            };

            node.* = .{ .data = event };
            self.queue.prepend(node);
        }

        pub fn pop(self: *Self) ?Event {
            var node = self.queue.pop();
            if (node) |n| {
                const event = n.data;
                self.allocator.destroy(n);

                return event;
            }

            return null;
        }
    };
}

pub fn RenderGraphicsFn(comptime Context: type) type {
    return fn (
        context: *?Context,
        parameters: []const f32,
        in_events: *EventQueue(WindowEvent),
        out_events: *EventQueue(UiEvent),
        bits: Bitmap,
    ) void;
}
