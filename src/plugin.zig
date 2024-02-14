const std = @import("std");
const print = std.debug.print;
const dlog = std.log.debug;

const clap = @import("plugin_clap.zig");
const text = @import("text");
const Pixel = clap.Pixel;
const Coord = clap.Coord;
const Bitmap = clap.Bitmap;
const Color = clap.Color;

// Logging
const logging = @import("logging.zig");
pub const std_options = struct {
    pub const log_level = .debug;
    pub const logFn = logging.log;
};

const DragGesture = struct {
    param: Parameter,
    start_coord: Coord,
    start_value: f32,
};

const GraphicsCtx = struct {
    mouse_down: bool,
    mouse_pos: clap.Coord,
    drag_gesture: ?DragGesture,
    text_bitmap: Bitmap,
};

const Parameter = enum(usize) {
    volume = 0,
};

const param_data = [_]clap.ParameterData{.{
    .min_value = 0,
    .max_value = 1,
    .default_value = 0.5,
    .name = "Volume",
}};

const Rect = struct {
    pos: Pixel,
    size: Pixel,
};

// Create plugin type
const Plugin = clap.Plugin(
    clap.Options{
        .name = "HelloCLAP",
        .plugin_type = .instrument,
        .version = "0.0.0",
        .description = "The best audio plugin ever.",
        .param_data = &param_data,
        .GraphicsContext = GraphicsCtx,
    },
);

// Create entrypoint
export const clap_entry = Plugin.createEntryPoint(
    renderAudioSynth,
    renderGraphics,
);

// Font shit
const font_file = @embedFile("res/Marco_old_kern.ttf");

fn drawBorderRect(
    bitmap: Bitmap,
    rect: Rect,
    border_width: u32,
    color: Color,
) void {
    // Vertical borders
    for (rect.pos.y..(rect.pos.y + rect.size.y)) |y| {
        for (0..border_width) |offset| {
            // Left
            bitmap.set(.{
                .x = rect.pos.x + offset,
                .y = y,
            }, color);

            // Right
            bitmap.set(.{
                .x = rect.pos.x + rect.size.x - 1 - offset,
                .y = y,
            }, color);
        }
    }

    // Horizontal borders
    for (rect.pos.x..(rect.pos.x + rect.size.x)) |x| {
        for (0..border_width) |offset| {
            // Top
            bitmap.set(.{
                .x = x,
                .y = rect.pos.y + offset,
            }, color);

            // Bottom
            bitmap.set(.{
                .x = x,
                .y = rect.pos.y + rect.size.y - 1 - offset,
            }, color);
        }
    }
}

fn drawRect(
    bitmap: Bitmap,
    rect: Rect,
    color: Color,
) void {
    for (rect.pos.y..(rect.pos.y + rect.size.y)) |y| {
        for (rect.pos.x..(rect.pos.x + rect.size.x)) |x| {
            bitmap.set(.{
                .x = x,
                .y = y,
            }, color);
        }
    }
}

fn copyBitmap(
    dest: Bitmap,
    src: Bitmap,
    x: usize,
    y: usize,
) void {
    const x_max: usize = x + src.width;
    const y_max: usize = y + src.height;
    for (x..x_max, 0..) |i, p| {
        for (y..y_max, 0..) |j, q| {
            if (i < 0 or i >= dest.width or
                j < 0 or j >= dest.height)
            {
                continue;
            }

            var src_color = src.get(.{ .x = p, .y = q });
            var dst_color = dest.get(.{ .x = i, .y = j });
            const alpha: f32 = @as(f32, @floatFromInt(src_color.c.a)) / 255.0;
            var color: Color = .{ .c = .{
                .r = @intFromFloat(@as(f32, @floatFromInt(src_color.c.r)) * alpha + @as(f32, @floatFromInt(dst_color.c.r)) * (1 - alpha)),
                .g = @intFromFloat(@as(f32, @floatFromInt(src_color.c.g)) * alpha + @as(f32, @floatFromInt(dst_color.c.g)) * (1 - alpha)),
                .b = @intFromFloat(@as(f32, @floatFromInt(src_color.c.b)) * alpha + @as(f32, @floatFromInt(dst_color.c.b)) * (1 - alpha)),
                .a = 255,
            } };

            dest.set(
                .{ .x = i, .y = j },
                color,
            );
        }
    }
}

fn renderGraphics(
    context: *?GraphicsCtx,
    parameters: []const f32,
    in_events: *clap.EventQueue(clap.WindowEvent),
    out_events: *clap.EventQueue(clap.UiEvent),
    bitmap: Bitmap,
) void {
    // Initialize context
    if (context.* == null) {
        context.* = GraphicsCtx{
            .mouse_down = false,
            .mouse_pos = clap.Coord{ .x = 0, .y = 0 },
            .drag_gesture = null,
            .text_bitmap = Bitmap.create(clap.global_allocator, 640, 480) catch unreachable,
        };
        context.*.?.text_bitmap.clear();
        text.init(font_file, &context.*.?.text_bitmap) catch unreachable;
    }

    // We know that context is no longer null
    var ctx: *GraphicsCtx = @ptrCast(context);

    while (in_events.pop()) |event| {
        switch (event) {
            .mouse_drag => |coord| {
                ctx.mouse_pos = coord;

                if (ctx.drag_gesture) |gesture| {
                    const parameter_index = @intFromEnum(gesture.param);
                    const current_value = gesture.start_value;
                    const max_value = param_data[parameter_index].max_value;
                    const min_value = param_data[parameter_index].min_value;
                    // TODO(oliver): make sensitivity variable
                    const value_change = @as(f32, @floatFromInt(gesture.start_coord.y - coord.y)) / 300.0;

                    out_events.push(clap.UiEvent{
                        .param_update = .{
                            .parameter = parameter_index,
                            .value = @min(@max(current_value + value_change, min_value), max_value),
                        },
                    });
                }
            },
            .mouse_press => |coord| {
                ctx.mouse_pos = coord;
                ctx.mouse_down = true;

                dlog("Click!", .{});
                if (ctx.drag_gesture == null and
                    coord.x >= 24 and
                    coord.x <= bitmap.width - 24 and
                    coord.y >= 24 and
                    coord.y <= bitmap.height - 24)
                {
                    dlog("Start Drag", .{});
                    ctx.drag_gesture = DragGesture{
                        .param = Parameter.volume,
                        .start_coord = coord,
                        .start_value = parameters[@intFromEnum(Parameter.volume)],
                    };
                }
            },
            .mouse_release => {
                dlog("Release!", .{});
                if (ctx.mouse_down) {
                    ctx.mouse_down = false;
                    ctx.drag_gesture = null;
                }
            },
        }
    }

    drawRect(
        bitmap,
        .{
            .pos = .{
                .x = 0,
                .y = 0,
            },
            .size = .{
                .x = bitmap.width,
                .y = bitmap.height,
            },
        },
        Color{ .i = 0x1F1F1F },
    );

    const volume_index = @intFromEnum(Parameter.volume);
    const volume_slider_width: u32 = bitmap.width - 48;
    const volume_slider_height: u32 = bitmap.height - 48;
    const volume_slider_fill_height: u32 = @intFromFloat(
        @as(f32, @floatFromInt(volume_slider_height)) * parameters[volume_index],
    );

    drawRect(
        bitmap,
        .{
            .pos = .{
                .x = 24,
                .y = 24 + volume_slider_height - volume_slider_fill_height,
            },
            .size = .{
                .x = volume_slider_width,
                .y = volume_slider_fill_height,
            },
        },
        Color{ .i = 0x2BC454 },
    );

    drawBorderRect(
        bitmap,
        .{
            .pos = .{
                .x = 24,
                .y = 24,
            },
            .size = .{
                .x = volume_slider_width,
                .y = volume_slider_height,
            },
        },
        4,
        Color{ .i = 0xe3e3e3 },
    );

    copyBitmap(bitmap, ctx.text_bitmap, 0, 0);
}

fn renderAudioGain(
    sample_rate: f32,
    parameters: []const f32,
    parameter_offsets: []const f32,
    in_frame: clap.StereoFrame,
    output_frame: clap.StereoFrame,
) void {
    _ = sample_rate;
    const parameter_idx = @intFromEnum(Parameter.volume);

    for (0..output_frame.len) |idx| {
        const volume = std.math.clamp(
            parameters[parameter_idx] + parameter_offsets[parameter_idx],
            0,
            1,
        );

        output_frame.left[idx] = in_frame.left[idx] * volume;
        output_frame.right[idx] = in_frame.right[idx] * volume;
    }
}

fn renderAudioSynth(
    sample_rate: f32,
    parameters: []const f32,
    parameter_offsets: []const f32,
    voices: []Plugin.Voice,
    output_frame: clap.StereoFrame,
) void {
    _ = parameter_offsets;
    for (0..output_frame.len) |idx| {
        var sum: f32 = 0.0;
        for (voices) |*voice| {
            if (!voice.held) {
                continue;
            }
            const parameter_idx = @intFromEnum(Parameter.volume);
            const volume = std.math.clamp(
                parameters[parameter_idx] + voice.parameter_offsets[parameter_idx],
                0,
                1,
            );
            sum += @sin(voice.phase * 2.0 * std.math.pi) * 0.2 * volume;
            voice.phase += 440.0 * @exp2((@as(f32, @floatFromInt(voice.key)) - 57.0) / 12.0) / sample_rate;
            voice.phase -= @floor(voice.phase);
        }

        output_frame.left[idx] = sum;
        output_frame.right[idx] = sum;
    }
}
