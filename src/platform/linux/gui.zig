const std = @import("std");
const err = std.log.err;
const dlog = std.log.debug;

const clap = @import("clap");
const shared = @import("gui_shared");
pub usingnamespace shared;

const c = @cImport({
    @cDefine("XUTIL_DEFINE_FUNCTIONS", {});
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xatom.h");
});

// Exported Constants
pub const window_api = clap.CLAP_WINDOW_API_X11;
pub const width = 680;
pub const height = 400;

const CreateGuiError = error{
    OpenDisplayFailed,
    CreateWindowFailed,
};

pub fn Gui(comptime Context: type) type {
    const RenderGraphicsFn = shared.RenderGraphicsFn(Context);

    return struct {
        bitmap: shared.Bitmap,

        display: *c.Display,
        window: c.Window,
        image: *c.XImage,

        host: *const clap.host,
        host_posix_fd_support: ?*const clap.host_posix_fd_support,
        allocator: std.mem.Allocator,
        main_parameters: []const f32,
        context: *?Context,

        const Self = @This();

        pub fn create(
            allocator: std.mem.Allocator,
            host_posix_fd_support: ?*const clap.host_posix_fd_support,
            host: *const clap.host,
            main_parameters: []const f32,
            context: *?Context,
        ) !*Self {
            std.log.info("Creating GUI!", .{});

            var gui = try allocator.create(Self);
            errdefer allocator.destroy(gui);

            gui.allocator = allocator;
            gui.main_parameters = main_parameters;
            gui.context = context;
            gui.host = host;
            gui.host_posix_fd_support = host_posix_fd_support;

            if (c.XOpenDisplay(null)) |display| {
                gui.display = display;
            } else {
                return CreateGuiError.OpenDisplayFailed;
            }
            errdefer _ = c.XCloseDisplay(gui.display);

            var attributes = std.mem.zeroes(c.XSetWindowAttributes);
            // TODO(oliver): Handle errors
            gui.window = c.XCreateWindow(
                gui.display,
                c.DefaultRootWindow(gui.display),
                0, // x
                0, // y
                width,
                height,
                0, // border_width
                0, // depth
                c.InputOutput, // class
                c.CopyFromParent, // visual
                c.CWOverrideRedirect, // valuemask
                &attributes,
            );
            errdefer _ = c.XDestroyWindow(gui.display, gui.window);

            _ = c.XStoreName(gui.display, gui.window, "SuperElectric");

            const embedInfoAtom: c.Atom = c.XInternAtom(
                gui.display,
                "_XEMBED_INFO",
                @intFromBool(false),
            );

            const embedInfoData = [_]u32{
                0, // version
                0, // not mapped
            };

            _ = c.XChangeProperty(
                gui.display,
                gui.window,
                embedInfoAtom,
                embedInfoAtom,
                32,
                c.PropModeReplace,
                @ptrCast(&embedInfoData),
                2,
            );

            var sizeHints: c.XSizeHints = std.mem.zeroes(c.XSizeHints);
            sizeHints.flags = c.PMinSize | c.PMaxSize;
            sizeHints.min_width = width;
            sizeHints.max_width = width;
            sizeHints.min_height = height;
            sizeHints.max_height = height;
            c.XSetWMNormalHints(@ptrCast(gui.display), gui.window, &sizeHints);

            // Select events window will receive
            _ = c.XSelectInput(
                gui.display,
                gui.window,
                c.SubstructureNotifyMask |
                    c.ExposureMask |
                    c.PointerMotionMask |
                    c.ButtonPressMask |
                    c.ButtonReleaseMask |
                    c.KeyPressMask |
                    c.KeyReleaseMask |
                    c.StructureNotifyMask |
                    c.EnterWindowMask |
                    c.LeaveWindowMask |
                    c.ButtonMotionMask |
                    c.KeymapStateMask |
                    c.FocusChangeMask |
                    c.PropertyChangeMask,
            );

            // Create bitmap to draw on
            gui.image = c.XCreateImage(
                gui.display,
                c.DefaultVisual(gui.display, 0),
                24,
                c.ZPixmap,
                0,
                null,
                10,
                10,
                32,
                0,
            );
            errdefer {
                _ = c.XDestroyImage(gui.image);
            }

            gui.bitmap = .{
                .width = width,
                .height = height,
                .bits = try allocator.alloc(shared.Color, width * height),
            };

            errdefer {
                gui.image.data = null;
                allocator.free(gui.bitmap.bits);
            }

            gui.image.width = width;
            gui.image.height = height;
            gui.image.bytes_per_line = width * 4;
            gui.image.data = @ptrCast(gui.bitmap.bits);

            // register fd
            if (host_posix_fd_support) |hpfd| {
                _ = hpfd.register_fd.?(
                    host,
                    c.ConnectionNumber(gui.display),
                    clap.CLAP_POSIX_FD_READ,
                );
            }

            return gui;
        }

        pub fn destroy(
            gui: *Self,
        ) void {
            std.log.info("Destroying GUI!", .{});

            if (gui.host_posix_fd_support) |hpfd| {
                _ = hpfd.unregister_fd.?(gui.host, c.ConnectionNumber(gui.display));
            }

            gui.allocator.free(gui.bitmap.bits);
            gui.image.data = null;
            _ = c.XDestroyImage(gui.image);
            _ = c.XDestroyWindow(@ptrCast(gui.display), gui.window);
            _ = c.XCloseDisplay(@ptrCast(gui.display));

            gui.allocator.destroy(gui);
        }

        fn blit(
            gui: *Self,
        ) void {
            _ = c.XPutImage(
                gui.display,
                gui.window,
                c.DefaultGC(gui.display, 0),
                gui.image,
                0,
                0,
                0,
                0,
                width,
                height,
            );
        }

        fn processX11Event(
            gui: *Self,
            xevent: *const c.XEvent,
        ) !?shared.WindowEvent {
            var event: ?shared.WindowEvent = null;
            switch (xevent.type) {
                c.Expose => {
                    if (xevent.xexpose.window == gui.window) {
                        gui.blit();
                    }
                },
                c.MotionNotify => {
                    if (xevent.xmotion.window == gui.window) {
                        event = shared.WindowEvent{
                            .mouse_drag = .{
                                .x = @intCast(xevent.xmotion.x),
                                .y = @intCast(xevent.xmotion.y),
                            },
                        };
                    }
                },
                c.ButtonPress => {
                    if (xevent.xbutton.window == gui.window) {
                        _ = c.XGrabPointer(
                            gui.display,
                            gui.window,
                            c.False,
                            c.PointerMotionMask |
                                c.ButtonPressMask |
                                c.ButtonReleaseMask,
                            c.GrabModeAsync,
                            c.GrabModeAsync,
                            c.None,
                            c.None,
                            c.CurrentTime,
                        );

                        event = shared.WindowEvent{
                            .mouse_press = .{
                                .x = @intCast(xevent.xbutton.x),
                                .y = @intCast(xevent.xbutton.y),
                            },
                        };
                    }
                },
                c.ButtonRelease => {
                    _ = c.XUngrabPointer(gui.display, c.CurrentTime);
                    event = @as(shared.WindowEvent, .mouse_release);
                },
                else => {
                    // pass
                },
            }

            return event;
        }

        pub fn redraw(
            gui: *Self,
            out_events: *shared.EventQueue(shared.UiEvent),
            comptime renderGraphics: RenderGraphicsFn,
        ) !void {
            var arena = std.heap.ArenaAllocator.init(gui.allocator);
            defer arena.deinit();

            const arenaAlloc = arena.allocator();
            var event_queue = shared.EventQueue(shared.WindowEvent).init(arenaAlloc);
            defer event_queue.deinit();

            _ = c.XFlush(gui.display);
            if (c.XPending(gui.display) != 0) {
                var event: c.XEvent = undefined;
                _ = c.XNextEvent(gui.display, &event);

                while (c.XPending(gui.display) != 0) {
                    var event0: c.XEvent = undefined;
                    _ = c.XNextEvent(gui.display, &event);

                    if (event.type == c.MotionNotify and
                        event0.type == c.MotionNotify)
                    {
                        // NOTE(oliver): merge adjacent mouse motion events
                    } else {
                        if (try gui.processX11Event(&event)) |e| {
                            event_queue.push(e);
                        }
                        _ = c.XFlush(gui.display);
                    }

                    event = event0;
                }

                if (try gui.processX11Event(&event)) |e| {
                    event_queue.push(e);
                }
                _ = c.XFlush(gui.display);
            }

            event_queue.read_only = true;
            renderGraphics(
                gui.context,
                gui.main_parameters,
                &event_queue,
                out_events,
                gui.bitmap,
            );
            gui.blit();

            _ = c.XFlush(gui.display);
        }

        pub fn setParent(gui: *Self, window: *const clap.window) void {
            std.log.info("Setting GUI window parent", .{});

            _ = c.XReparentWindow(gui.display, gui.window, @as(c.Window, window.unnamed_0.x11), 0, 0);
        }

        pub fn setVisible(gui: *Self, visible: bool) void {
            std.log.info("Setting GUI window visibility: {}", .{visible});

            if (visible) {
                _ = c.XMapRaised(gui.display, gui.window);
            } else {
                _ = c.XUnmapWindow(gui.display, gui.window);
            }
            _ = c.XFlush(gui.display);
        }
    };
}
