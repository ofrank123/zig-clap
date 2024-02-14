const std = @import("std");
const print = std.debug.print;

const clap = @import("clap");
const gui = @import("gui");
const logging = @import("logging.zig");

pub usingnamespace gui;

// Global Allocator
var global_gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub var global_allocator = global_gpa.allocator();

const instrument_features = &[_:null]?[*:0]const u8{
    clap.CLAP_PLUGIN_FEATURE_INSTRUMENT,
    clap.CLAP_PLUGIN_FEATURE_SYNTHESIZER,
    clap.CLAP_PLUGIN_FEATURE_STEREO,
};

const effect_features = &[_:null]?[*:0]const u8{
    clap.CLAP_PLUGIN_FEATURE_AUDIO_EFFECT,
    clap.CLAP_PLUGIN_FEATURE_UTILITY,
    clap.CLAP_PLUGIN_FEATURE_STEREO,
};

pub const ParameterData = struct {
    min_value: f32,
    max_value: f32,
    default_value: f32,
    name: []const u8,
};

pub const PluginType = enum {
    instrument,
    effect,
};

pub const StereoFrame = struct {
    len: usize,
    left: []f32,
    right: []f32,
};

/// Options required to create CLAP plugin
pub const Options = struct {
    name: [*:0]const u8,
    plugin_type: PluginType,
    version: [*:0]const u8,
    description: [*:0]const u8,
    param_data: []const ParameterData,
    GraphicsContext: type,
};

pub fn Plugin(comptime options: Options) type {
    const Gui = gui.Gui(options.GraphicsContext);
    const RenderGraphicsFn = gui.RenderGraphicsFn(options.GraphicsContext);

    return struct {
        const Self = @This();
        const plugin_type = options.plugin_type;
        const parameter_count = options.param_data.len;

        clap_plugin: clap.plugin,
        host: *const clap.host,
        sample_rate: f32,
        voices: std.ArrayList(Voice),
        gui: ?*Gui = null,
        timer_id: clap.id,

        // Host extensions
        host_posix_fd_support: ?*const clap.host_posix_fd_support = null,
        host_timer_support: ?*const clap.host_timer_support = null,

        // Parameters
        parameter_sync_lock: std.Thread.Mutex,
        parameters: [parameter_count]f32 =
            [_]f32{0} ** parameter_count,
        parameters_changed: [parameter_count]bool =
            [_]bool{false} ** parameter_count,
        parameter_offsets: [parameter_count]f32 =
            [_]f32{0} ** parameter_count,

        main_parameters: [parameter_count]f32 =
            [_]f32{0} ** parameter_count,
        main_parameters_changed: [parameter_count]bool =
            [_]bool{false} ** parameter_count,

        // Contexts
        graphics_context: ?options.GraphicsContext,

        pub const Voice = struct {
            held: bool,
            note_id: i32,
            channel: i16,
            key: i16,
            phase: f32,
            parameter_offsets: [parameter_count]f32 = [_]f32{0} ** parameter_count,
        };

        const InstrumentRenderAudioFn = fn (
            sample_rate: f32,
            parameters: []const f32,
            parameters_offset: []const f32,
            voices: []Voice,
            output_frame: StereoFrame,
        ) void;

        const EffectRenderAudioFn = fn (
            sample_rate: f32,
            parameters: []const f32,
            parameters_offset: []const f32,
            in_frame: StereoFrame,
            output_frame: StereoFrame,
        ) void;

        pub const RenderAudioFn = if (options.plugin_type == PluginType.effect)
            EffectRenderAudioFn
        else
            InstrumentRenderAudioFn;

        /// Creates the entry point for a CLAP plugin
        pub fn createEntryPoint(
            comptime renderAudio: RenderAudioFn,
            comptime renderGraphics: RenderGraphicsFn,
        ) clap.plugin_entry {
            const plugin_descriptor = createPluginDescriptor();
            const plugin_class = createPluginClass(
                &plugin_descriptor,
                renderAudio,
                renderGraphics,
            );

            const plugin_factory = createPluginFactory(
                &plugin_class,
                &plugin_descriptor,
            );

            const PluginEntry = struct {
                fn init(_: [*c]const u8) callconv(.C) bool {
                    std.log.debug("Fn: init", .{});
                    return true;
                }

                fn deinit() callconv(.C) void {
                    std.log.debug("Fn: deinit", .{});
                    const leak_check = global_gpa.deinit();
                    if (leak_check == std.heap.Check.leak) {
                        std.log.warn("Leak Detected!\n", .{});
                    }
                }

                fn get_factory(factory_id_cstring: [*c]const u8) callconv(.C) ?*const anyopaque {
                    std.log.debug("Fn: get_factory", .{});
                    const factory_id: [:0]const u8 = std.mem.span(factory_id_cstring);
                    if (std.mem.eql(u8, factory_id, &clap.CLAP_PLUGIN_FACTORY_ID)) {
                        return &plugin_factory;
                    }
                    return null;
                }
            };

            return clap.plugin_entry{
                .clap_version = clap.CLAP_VERSION_INIT,
                .init = PluginEntry.init,
                .deinit = PluginEntry.deinit,
                .get_factory = PluginEntry.get_factory,
            };
        }

        fn unwrapPluginData(clap_plugin: *const clap.plugin) *Self {
            return @alignCast(@ptrCast(clap_plugin.plugin_data.?));
        }

        fn syncMainToAudio(plugin: *Self, out: *const clap.output_events) void {
            plugin.parameter_sync_lock.lock();
            defer plugin.parameter_sync_lock.unlock();

            for (0..parameter_count) |param_idx| {
                if (plugin.main_parameters_changed[param_idx]) {
                    plugin.parameters[param_idx] = plugin.main_parameters[param_idx];
                    plugin.main_parameters_changed[param_idx] = false;

                    const event = clap.event_param_value{
                        .header = clap.event_header{
                            .size = @sizeOf(clap.event_param_value),
                            .time = 0,
                            .space_id = clap.CLAP_CORE_EVENT_SPACE_ID,
                            .type = clap.CLAP_EVENT_PARAM_VALUE,
                            .flags = 0,
                        },
                        .param_id = @intCast(param_idx),
                        .cookie = null,
                        .note_id = -1,
                        .port_index = -1,
                        .channel = -1,
                        .key = -1,
                        .value = plugin.parameters[param_idx],
                    };
                    _ = out.try_push(out, @ptrCast(&event));
                }
            }
        }

        fn syncAudioToMain(plugin: *Self) bool {
            var any_changed = false;
            plugin.parameter_sync_lock.lock();
            defer plugin.parameter_sync_lock.unlock();

            for (0..parameter_count) |param_idx| {
                if (plugin.parameters_changed[param_idx]) {
                    plugin.main_parameters[param_idx] = plugin.parameters[param_idx];
                    plugin.parameters_changed[param_idx] = false;
                    any_changed = true;
                }
            }

            return any_changed;
        }

        fn processUiEvents(plugin: *Self, events: *gui.EventQueue(gui.UiEvent)) void {
            while (events.pop()) |event| {
                switch (event) {
                    .param_update => |update| {
                        plugin.main_parameters[update.parameter] = update.value;
                        plugin.main_parameters_changed[update.parameter] = true;
                    },
                }
            }
        }

        fn createPluginDescriptor() clap.plugin_descriptor {
            return clap.plugin_descriptor{
                .clap_version = clap.CLAP_VERSION_INIT,
                .id = "superelectric.HelloCLAP",
                .name = options.name,
                .vendor = "superelectric",
                .url = "https://superelectric.dev",
                .manual_url = "https://superelectric.dev",
                .support_url = "https://superelectric.dev",
                .version = options.version,
                .description = options.description,
                .features = if (plugin_type == PluginType.instrument)
                    instrument_features
                else
                    effect_features,
            };
        }

        fn processEvent(plugin: *Self, event: *const clap.event_header) void {
            if (event.space_id == clap.CLAP_CORE_EVENT_SPACE_ID) {
                switch (event.type) {
                    clap.CLAP_EVENT_NOTE_ON,
                    clap.CLAP_EVENT_NOTE_OFF,
                    clap.CLAP_EVENT_NOTE_CHOKE,
                    => {
                        const note_event: *const clap.event_note = @alignCast(@ptrCast(event));

                        // Search through voices, if the event matches, it must have been released
                        var i: u32 = 0;
                        while (i < plugin.voices.items.len) : (i += 1) {
                            var voice = &plugin.voices.items[i];

                            if ((note_event.key == -1 or
                                voice.key == note_event.key) and
                                (note_event.note_id == -1 or
                                voice.note_id == note_event.note_id) and
                                (note_event.channel == -1 or
                                voice.channel == note_event.channel))
                            {
                                if (event.type == clap.CLAP_EVENT_NOTE_CHOKE) {
                                    _ = plugin.voices.swapRemove(i);
                                    i -= 1;
                                } else {
                                    voice.held = false;
                                }
                            }
                        }

                        // If this is a note on, make a new voice
                        if (event.type == clap.CLAP_EVENT_NOTE_ON) {
                            const voice = Voice{
                                .held = true,
                                .note_id = note_event.note_id,
                                .channel = note_event.channel,
                                .key = note_event.key,
                                .phase = 0,
                            };

                            plugin.voices.append(voice) catch std.log.err("FAILED TO ADD NEW VOICE!\n", .{});
                        }
                    },
                    clap.CLAP_EVENT_PARAM_VALUE => {
                        const value_event: *const clap.event_param_value = @alignCast(@ptrCast(event));
                        const parameter_idx: usize = value_event.param_id;
                        {
                            plugin.parameter_sync_lock.lock();
                            defer plugin.parameter_sync_lock.unlock();

                            plugin.parameters[parameter_idx] = @floatCast(value_event.value);
                            plugin.parameters_changed[parameter_idx] = true;
                        }
                    },
                    clap.CLAP_EVENT_PARAM_MOD => {
                        const mod_event: *const clap.event_param_mod = @alignCast(@ptrCast(event));

                        if (mod_event.key == -1 and
                            mod_event.note_id == -1 and
                            mod_event.channel == -1)
                        {
                            plugin.parameter_offsets[mod_event.param_id] = @floatCast(mod_event.amount);
                        }

                        for (plugin.voices.items) |*voice| {
                            if ((mod_event.key == -1 or voice.key == mod_event.key) and
                                (mod_event.note_id == -1 or voice.note_id == mod_event.note_id) and
                                (mod_event.channel == -1 or voice.channel == mod_event.channel))
                            {
                                // NOTE(oliver): We are just going to override with the most recent voices'
                                // offset, because I can't think of a sensible way to handle polyphonic
                                // modulation on an effect
                                if (plugin_type == PluginType.effect) {
                                    plugin.parameter_offsets[mod_event.param_id] = @floatCast(mod_event.amount);
                                }

                                voice.parameter_offsets[mod_event.param_id] = @floatCast(mod_event.amount);
                                break;
                            }
                        }
                    },
                    else => {
                        // Ignore Event
                    },
                }
            }
        }

        fn createPluginClass(
            comptime descriptor: *const clap.plugin_descriptor,
            comptime renderAudio: RenderAudioFn,
            comptime renderGraphics: RenderGraphicsFn,
        ) clap.plugin {
            const audio_ports_ext = createAudioPortsExt();
            const note_ports_ext = createNotePortsExt();
            const params_ext = createParamsExt();
            const state_ext = createStateExt();
            const gui_ext = createGuiExt();
            const fd_ext = createPosixFdSupportExt(renderGraphics);
            const timer_ext = createTimerExt(renderGraphics);

            const PluginClass = struct {
                fn init(_plugin: *const clap.plugin) callconv(.C) bool {
                    std.log.debug("Fn: PluginClass.init", .{});
                    var plugin: *Self = unwrapPluginData(_plugin);

                    {
                        plugin.parameter_sync_lock.lock();
                        defer plugin.parameter_sync_lock.unlock();

                        for (0..parameter_count) |param_idx| {
                            var information: clap.param_info = std.mem.zeroes(clap.param_info);
                            _ = params_ext.get_info(_plugin, @intCast(param_idx), &information);
                            plugin.parameters[param_idx] = @floatCast(information.default_value);
                            plugin.main_parameters[param_idx] = @floatCast(information.default_value);
                        }
                    }

                    if (plugin.host_timer_support) |hts| {
                        _ = hts.register_timer.?(
                            plugin.host,
                            100, // milliseconds
                            &plugin.timer_id,
                        );
                    }

                    return true;
                }

                fn destroy(_plugin: *const clap.plugin) callconv(.C) void {
                    std.log.debug("Fn: PluginClass.destroy", .{});
                    var plugin: *Self = unwrapPluginData(_plugin);
                    if (plugin.host_timer_support) |hts| {
                        _ = hts.unregister_timer.?(
                            plugin.host,
                            plugin.timer_id,
                        );
                    }
                    plugin.voices.deinit();
                    global_allocator.destroy(plugin);
                }

                fn activate(_plugin: *const clap.plugin, sample_rate: f64, minimum_frames_count: u32, maximum_frames_count: u32) callconv(.C) bool {
                    std.log.debug("Fn: PluginClass.activate", .{});
                    _ = maximum_frames_count;
                    _ = minimum_frames_count;
                    var plugin: *Self = unwrapPluginData(_plugin);
                    plugin.sample_rate = @floatCast(sample_rate);
                    return true;
                }

                fn deactivate(_plugin: *const clap.plugin) callconv(.C) void {
                    std.log.debug("Fn: PluginClass.deactivate", .{});
                    _ = _plugin;
                }

                fn start_processing(_plugin: *const clap.plugin) callconv(.C) bool {
                    std.log.debug("Fn: PluginClass.startProcessing", .{});
                    _ = _plugin;
                    return true;
                }

                fn stop_processing(_plugin: *const clap.plugin) callconv(.C) void {
                    std.log.debug("Fn: PluginClass.stopProcessing", .{});
                    _ = _plugin;
                }

                fn reset(_plugin: *const clap.plugin) callconv(.C) void {
                    std.log.debug("Fn: PluginClass.reset", .{});
                    var plugin: *Self = unwrapPluginData(_plugin);
                    plugin.voices.deinit();
                }

                fn process(_plugin: *const clap.plugin, process_data: *const clap.process) callconv(.C) clap.process_status {
                    var plugin: *Self = unwrapPluginData(_plugin);

                    plugin.syncMainToAudio(process_data.out_events);

                    std.debug.assert(process_data.audio_outputs_count == 1);

                    if (plugin_type == PluginType.instrument) {
                        std.debug.assert(process_data.audio_inputs_count == 0);
                    } else {
                        std.debug.assert(process_data.audio_inputs_count == 1);
                    }

                    const frame_count: u32 = process_data.frames_count;
                    const input_event_count: u32 = process_data.in_events.*.size(process_data.in_events);
                    var event_idx: u32 = 0;
                    var next_event_frame = if (input_event_count > 0) 0 else frame_count;

                    {
                        var sample_idx: u32 = 0;
                        while (sample_idx < frame_count) {
                            while (event_idx < input_event_count and next_event_frame == sample_idx) {
                                const event: *const clap.event_header = process_data.in_events.*.get(
                                    process_data.in_events,
                                    event_idx,
                                );

                                if (event.time != sample_idx) {
                                    next_event_frame = event.time;
                                    break;
                                }

                                processEvent(plugin, event);
                                event_idx += 1;

                                if (event_idx == input_event_count) {
                                    next_event_frame = frame_count;
                                    break;
                                }
                            }

                            var audio_output: *clap.audio_buffer = @ptrCast(&process_data.audio_outputs[0]);

                            var output_frame = StereoFrame{
                                .len = next_event_frame - sample_idx,
                                .left = audio_output.data32[0][sample_idx..next_event_frame],
                                .right = audio_output.data32[1][sample_idx..next_event_frame],
                            };

                            if (plugin_type == PluginType.instrument) {
                                renderAudio(
                                    plugin.sample_rate,
                                    plugin.parameters[0..],
                                    plugin.parameter_offsets[0..],
                                    plugin.voices.items,
                                    output_frame,
                                );
                            } else {
                                const audio_input: *const clap.audio_buffer =
                                    @ptrCast(&process_data.audio_inputs[0]);

                                const input_frame = StereoFrame{
                                    .len = next_event_frame - sample_idx,
                                    .left = audio_input.data32[0][sample_idx..next_event_frame],
                                    .right = audio_input.data32[1][sample_idx..next_event_frame],
                                };

                                renderAudio(
                                    plugin.sample_rate,
                                    plugin.parameters[0..],
                                    plugin.parameter_offsets[0..],
                                    input_frame,
                                    output_frame,
                                );
                            }

                            sample_idx = next_event_frame;
                        }
                    }

                    // Remove finished voices, and send event
                    var voice_idx: u32 = 0;
                    while (voice_idx < plugin.voices.items.len) {
                        const voice: *Voice = &plugin.voices.items[voice_idx];

                        if (!voice.held) {
                            const event = clap.event_note{
                                .header = clap.event_header{
                                    .size = @sizeOf(clap.event_note),
                                    .time = 0,
                                    .space_id = clap.CLAP_CORE_EVENT_SPACE_ID,
                                    .type = clap.CLAP_EVENT_NOTE_END,
                                    .flags = 0,
                                },
                                .key = voice.key,
                                .note_id = voice.note_id,
                                .channel = voice.channel,
                                .port_index = 0,
                                .velocity = 0,
                            };
                            _ = process_data.out_events.*.try_push(
                                process_data.out_events,
                                &event.header,
                            );
                            _ = plugin.voices.swapRemove(voice_idx);

                            // Don't increase idx on removal
                        } else {
                            voice_idx += 1;
                        }
                    }

                    return clap.CLAP_PROCESS_CONTINUE;
                }

                fn get_extension(_plugin: *const clap.plugin, id_cstr: [*:0]const u8) callconv(.C) ?*const anyopaque {
                    std.log.debug("Fn: PluginClass.getExtension", .{});
                    _ = _plugin;
                    const id: [:0]const u8 = std.mem.span(id_cstr);
                    if (std.mem.eql(u8, id, &clap.CLAP_EXT_NOTE_PORTS)) {
                        return @ptrCast(&note_ports_ext);
                    }
                    if (std.mem.eql(u8, id, &clap.CLAP_EXT_AUDIO_PORTS)) {
                        return @ptrCast(&audio_ports_ext);
                    }
                    if (std.mem.eql(u8, id, &clap.CLAP_EXT_PARAMS)) {
                        return @ptrCast(&params_ext);
                    }
                    if (std.mem.eql(u8, id, &clap.CLAP_EXT_STATE)) {
                        return @ptrCast(&state_ext);
                    }
                    if (std.mem.eql(u8, id, &clap.CLAP_EXT_GUI)) {
                        return @ptrCast(&gui_ext);
                    }
                    if (std.mem.eql(u8, id, &clap.CLAP_EXT_POSIX_FD_SUPPORT)) {
                        return @ptrCast(&fd_ext);
                    }
                    if (std.mem.eql(u8, id, &clap.CLAP_EXT_TIMER_SUPPORT)) {
                        return @ptrCast(&timer_ext);
                    }

                    return null;
                }

                fn on_main_thread(_plugin: *const clap.plugin) callconv(.C) void {
                    std.log.debug("Fn: PluginClass.onMainThread", .{});
                    _ = _plugin;
                }
            };

            return clap.plugin{
                .desc = descriptor,
                .plugin_data = null,

                .init = PluginClass.init,
                .destroy = PluginClass.destroy,
                .activate = PluginClass.activate,
                .deactivate = PluginClass.deactivate,
                .start_processing = PluginClass.start_processing,
                .stop_processing = PluginClass.stop_processing,
                .reset = PluginClass.reset,
                .process = PluginClass.process,
                .get_extension = PluginClass.get_extension,
                .on_main_thread = PluginClass.on_main_thread,
            };
        }

        fn createPluginFactory(
            comptime plugin_class: *const clap.plugin,
            comptime descriptor: *const clap.plugin_descriptor,
        ) clap.plugin_factory {
            const PluginFactory = struct {
                fn getPluginCount(factory: *const clap.plugin_factory) callconv(.C) u32 {
                    _ = factory;
                    std.log.debug("Fn: PluginFactory.get_plugin_count", .{});
                    return 1;
                }

                fn getPluginDescriptor(
                    factory: *const clap.plugin_factory,
                    index: u32,
                ) callconv(.C) ?*const clap.plugin_descriptor {
                    _ = factory;
                    std.log.debug("Fn: PluginFactory.get_plugin_descriptor", .{});
                    return if (index == 0) descriptor else null;
                }

                fn createPlugin(
                    factory: *const clap.plugin_factory,
                    host: *const clap.host,
                    plugin_id_cstring: [*:0]const u8,
                ) callconv(.C) ?*const clap.plugin {
                    std.log.debug("Fn: PluginFactory.create_plugin", .{});
                    _ = factory;

                    const plugin_id: [:0]const u8 = std.mem.span(plugin_id_cstring);
                    const plugin_descriptor_id: [:0]const u8 = std.mem.span(descriptor.id);
                    if (!clap.version_is_compatible(host.*.clap_version) or
                        !std.mem.eql(u8, plugin_id, plugin_descriptor_id))
                    {
                        return null;
                    }

                    // Setup Logging
                    logging.initLogging(host);

                    var plugin = global_allocator.create(Self) catch std.debug.panic("FAILED TO CREATE ALLOCATOR!\n", .{});
                    plugin.host = host;
                    plugin.voices = std.ArrayList(Voice).init(global_allocator);
                    plugin.gui = null;
                    plugin.graphics_context = null;

                    plugin.clap_plugin = plugin_class.*;
                    plugin.clap_plugin.plugin_data = plugin;

                    if (host.get_extension.?(host, &clap.CLAP_EXT_POSIX_FD_SUPPORT)) |hostPosixFdSupport| {
                        std.log.info("POSIX FD extension acquired from host", .{});
                        plugin.host_posix_fd_support = @alignCast(@ptrCast(hostPosixFdSupport));
                    } else {
                        std.log.warn("POSIX FD extension not supported by host!", .{});
                    }

                    if (host.get_extension.?(host, &clap.CLAP_EXT_TIMER_SUPPORT)) |hostTimerSupport| {
                        std.log.info("Timer extension acquired from host", .{});
                        plugin.host_timer_support = @alignCast(@ptrCast(hostTimerSupport));
                    } else {
                        std.log.warn("Timer extension not supported by host!", .{});
                    }

                    return &plugin.clap_plugin;
                }
            };

            return clap.plugin_factory{
                .get_plugin_count = PluginFactory.getPluginCount,
                .get_plugin_descriptor = PluginFactory.getPluginDescriptor,
                .create_plugin = PluginFactory.createPlugin,
            };
        }

        // --------------------------------------------
        //                 Extensions
        // --------------------------------------------

        fn createAudioPortsExt() clap.plugin_audio_ports {
            const Extension = struct {
                fn count(plugin: *const clap.plugin, is_input: bool) callconv(.C) u32 {
                    _ = plugin;
                    std.log.info("Fn: EXT_AudioPorts.count", .{});
                    if (plugin_type == PluginType.instrument and is_input) {
                        return 0;
                    } else {
                        return 1;
                    }
                }

                fn get(
                    plugin: *const clap.plugin,
                    index: u32,
                    is_input: bool,
                    info: *clap.audio_port_info,
                ) callconv(.C) bool {
                    _ = plugin;
                    std.log.info("EXT: EXT_AudioPorts.get", .{});
                    if (index > 0) {
                        return false;
                    }

                    if (is_input) {
                        if (plugin_type == PluginType.instrument) {
                            return false;
                        }

                        info.id = 0;
                        info.channel_count = 2;
                        info.flags = clap.CLAP_AUDIO_PORT_IS_MAIN;
                        info.port_type = &clap.CLAP_PORT_STEREO;
                        info.in_place_pair = clap.CLAP_INVALID_ID;

                        const name: [:0]const u8 = "Audio Input";
                        // NOTE(oliver): Need to copy the null byte here
                        info.name[0 .. name.len + 1].* = name[0 .. name.len + 1].*;
                    } else {
                        info.id = 0;
                        info.channel_count = 2;
                        info.flags = clap.CLAP_AUDIO_PORT_IS_MAIN;
                        info.port_type = &clap.CLAP_PORT_STEREO;
                        info.in_place_pair = clap.CLAP_INVALID_ID;

                        const name: [:0]const u8 = "Audio Output";
                        // NOTE(oliver): Need to copy the null byte here
                        info.name[0 .. name.len + 1].* = name[0 .. name.len + 1].*;
                    }

                    return true;
                }
            };

            return clap.plugin_audio_ports{
                .get = Extension.get,
                .count = Extension.count,
            };
        }

        fn createNotePortsExt() clap.plugin_note_ports {
            const Extension = struct {
                fn count(plugin: [*c]const clap.plugin, is_input: bool) callconv(.C) u32 {
                    std.log.info("Fn: EXT_NotePorts.count", .{});
                    _ = plugin;
                    return if (is_input) 1 else 0;
                }

                fn get(
                    plugin: [*c]const clap.plugin,
                    index: u32,
                    is_input: bool,
                    info_cptr: [*c]clap.note_port_info,
                ) callconv(.C) bool {
                    std.log.info("Fn: EXT_NotePorts.get", .{});
                    _ = plugin;

                    if (!is_input or index > 0) {
                        return false;
                    }

                    const info: *clap.note_port_info = info_cptr;
                    info.id = 0;
                    info.supported_dialects = clap.CLAP_NOTE_DIALECT_CLAP; // TODO: Support MIDI!
                    info.preferred_dialect = clap.CLAP_NOTE_DIALECT_CLAP;
                    const name: [:0]const u8 = "Note Port";
                    // NOTE(oliver): Need to copy the null byte here
                    info.name[0 .. name.len + 1].* = name[0 .. name.len + 1].*;

                    return true;
                }
            };

            return clap.plugin_note_ports{
                .get = Extension.get,
                .count = Extension.count,
            };
        }

        fn createParamsExt() clap.plugin_params {
            const Extension = struct {
                fn count(clap_plugin: *const clap.plugin) callconv(.C) u32 {
                    _ = clap_plugin;
                    return parameter_count;
                }

                fn get_info(clap_plugin: *const clap.plugin, index: u32, information: *clap.param_info) callconv(.C) bool {
                    _ = clap_plugin;

                    if (index >= parameter_count) {
                        return false;
                    }

                    const param_data = options.param_data[@intCast(index)];
                    const flags = blk: {
                        if (plugin_type == .instrument) {
                            break :blk clap.CLAP_PARAM_IS_AUTOMATABLE | clap.CLAP_PARAM_IS_MODULATABLE | clap.CLAP_PARAM_IS_MODULATABLE_PER_NOTE_ID;
                        } else {
                            break :blk clap.CLAP_PARAM_IS_AUTOMATABLE | clap.CLAP_PARAM_IS_MODULATABLE;
                        }
                    };

                    var name_buf = [_]u8{0} ** 256;
                    std.mem.copyForwards(u8, &name_buf, param_data.name);

                    information.* = clap.param_info{
                        .id = index,
                        .flags = flags,
                        .min_value = param_data.min_value,
                        .max_value = param_data.max_value,
                        .default_value = param_data.default_value,
                        .cookie = null,
                        .name = name_buf,
                        .module = [_]u8{0} ** 1024,
                    };

                    return true;
                }

                fn get_value(
                    clap_plugin: *const clap.plugin,
                    param_idx: clap.id,
                    value: *f64,
                ) callconv(.C) bool {
                    var plugin = unwrapPluginData(clap_plugin);
                    if (param_idx >= parameter_count) {
                        return false;
                    }

                    {
                        plugin.parameter_sync_lock.lock();
                        defer plugin.parameter_sync_lock.unlock();

                        if (plugin.main_parameters_changed[param_idx]) {
                            value.* = plugin.main_parameters[param_idx];
                        } else {
                            value.* = plugin.parameters[param_idx];
                        }
                    }

                    return true;
                }

                fn value_to_text(
                    clap_plugin: *const clap.plugin,
                    param_idx: clap.id,
                    value: f64,
                    display: [*:0]u8,
                    size: u32,
                ) callconv(.C) bool {
                    _ = clap_plugin;
                    if (param_idx >= parameter_count) {
                        return false;
                    }
                    _ = std.fmt.bufPrintZ(display[0..size], "{d}", .{value}) catch unreachable;
                    return true;
                }

                fn text_to_value(
                    clap_plugin: [*c]const clap.plugin,
                    param_idx: clap.id,
                    display: [*:0]const u8,
                    value: *f64,
                ) callconv(.C) bool {
                    _ = display;
                    _ = value;
                    _ = param_idx;
                    _ = clap_plugin;
                    return false;
                }

                fn flush(
                    clap_plugin: *const clap.plugin,
                    in: *const clap.input_events,
                    out: *const clap.output_events,
                ) callconv(.C) void {
                    var plugin = unwrapPluginData(clap_plugin);
                    const event_count: u32 = in.size(in);
                    plugin.syncMainToAudio(out);

                    for (0..event_count) |event_idx| {
                        processEvent(plugin, in.get(in, @intCast(event_idx)));
                    }
                }
            };

            return clap.plugin_params{
                .count = Extension.count,
                .get_value = Extension.get_value,
                .get_info = Extension.get_info,
                .value_to_text = Extension.value_to_text,
                .text_to_value = Extension.text_to_value,
                .flush = Extension.flush,
            };
        }

        fn createStateExt() clap.plugin_state {
            const Extension = struct {
                fn save(clap_plugin: *const clap.plugin, stream: *const clap.ostream) callconv(.C) bool {
                    const plugin: *Self = unwrapPluginData(clap_plugin);
                    _ = plugin.syncAudioToMain();

                    var bytes_written: usize = 0;
                    while (bytes_written < parameter_count) {
                        bytes_written += @intCast(stream.write(
                            stream,
                            plugin.main_parameters[(bytes_written / @sizeOf(f32))..].ptr,
                            @sizeOf(f32) * (parameter_count - bytes_written),
                        ));
                    }
                    return true;
                }

                fn load(clap_plugin: *const clap.plugin, stream: *const clap.istream) callconv(.C) bool {
                    var plugin: *Self = unwrapPluginData(clap_plugin);

                    {
                        plugin.parameter_sync_lock.lock();
                        defer plugin.parameter_sync_lock.unlock();

                        var bytes_read: usize = 0;
                        while (bytes_read < parameter_count) {
                            bytes_read += @intCast(stream.read(
                                stream,
                                plugin.main_parameters[(bytes_read / @sizeOf(f32))..].ptr,
                                @sizeOf(f32) * (parameter_count - bytes_read),
                            ));
                        }

                        for (0..plugin.main_parameters_changed.len) |param_idx| {
                            plugin.main_parameters_changed[param_idx] = true;
                        }
                    }

                    return true;
                }
            };

            return clap.plugin_state{
                .save = Extension.save,
                .load = Extension.load,
            };
        }

        fn createGuiExt() clap.plugin_gui {
            const Extension = struct {
                fn is_api_supported(self: *const clap.plugin, api: [*:0]const u8, isFloating: bool) callconv(.C) bool {
                    _ = self;
                    return std.mem.eql(u8, std.mem.span(api), &gui.window_api) and !isFloating;
                }

                fn get_preferred_api(self: *const clap.plugin, api: *[*:0]const u8, isFloating: *bool) callconv(.C) bool {
                    _ = self;
                    api.* = &gui.window_api;
                    isFloating.* = true;
                    return true;
                }

                fn create(self: *const clap.plugin, api: [*:0]const u8, isFloating: bool) callconv(.C) bool {
                    _ = isFloating;
                    _ = api;
                    var plugin = unwrapPluginData(self);
                    if (plugin.gui == null) {
                        plugin.gui = Gui.create(
                            global_allocator,
                            plugin.host_posix_fd_support,
                            plugin.host,
                            plugin.main_parameters[0..],
                            &plugin.graphics_context,
                        ) catch {
                            std.log.err("Failed to create GUI!", .{});
                            return false;
                        };
                    }
                    return true;
                }

                fn destroy(self: *const clap.plugin) callconv(.C) void {
                    const plugin = unwrapPluginData(self);
                    if (plugin.gui) |_gui| {
                        _gui.destroy();
                        plugin.gui = null;
                    }
                }

                fn set_scale(self: *const clap.plugin, scale: f64) callconv(.C) bool {
                    _ = scale;
                    _ = self;
                    return false;
                }

                fn get_size(self: *const clap.plugin, width: *u32, height: *u32) callconv(.C) bool {
                    _ = self;
                    width.* = gui.width;
                    height.* = gui.height;
                    return true;
                }

                fn can_resize(self: *const clap.plugin) callconv(.C) bool {
                    _ = self;
                    return false;
                }

                fn get_resize_hints(self: *const clap.plugin, hints: *clap.gui_resize_hints) callconv(.C) bool {
                    _ = hints;
                    _ = self;
                    return false;
                }

                fn adjust_size(self: *const clap.plugin, width: *u32, height: *u32) callconv(.C) bool {
                    return @This().get_size(self, width, height);
                }

                fn set_size(self: *const clap.plugin, width: u32, height: u32) callconv(.C) bool {
                    _ = height;
                    _ = width;
                    _ = self;
                    return true;
                }

                fn set_parent(self: *const clap.plugin, window: *const clap.window) callconv(.C) bool {
                    if (unwrapPluginData(self).gui) |_gui| {
                        _gui.setParent(window);
                    }
                    return true;
                }

                fn set_transient(self: *const clap.plugin, window: *const clap.window) callconv(.C) bool {
                    _ = window;
                    _ = self;
                    return false;
                }

                fn suggest_title(self: *const clap.plugin, title: [*:0]const u8) callconv(.C) void {
                    _ = title;
                    _ = self;
                }

                fn show(self: *const clap.plugin) callconv(.C) bool {
                    if (unwrapPluginData(self).gui) |_gui| {
                        _gui.setVisible(true);
                    }
                    return true;
                }

                fn hide(self: *const clap.plugin) callconv(.C) bool {
                    if (unwrapPluginData(self).gui) |_gui| {
                        _gui.setVisible(false);
                    }
                    return true;
                }
            };

            return clap.plugin_gui{
                .is_api_supported = Extension.is_api_supported,
                .get_preferred_api = Extension.get_preferred_api,
                .create = Extension.create,
                .destroy = Extension.destroy,
                .set_scale = Extension.set_scale,
                .get_size = Extension.get_size,
                .can_resize = Extension.can_resize,
                .get_resize_hints = Extension.get_resize_hints,
                .adjust_size = Extension.adjust_size,
                .set_size = Extension.set_size,
                .set_parent = Extension.set_parent,
                .set_transient = Extension.set_transient,
                .suggest_title = Extension.suggest_title,
                .show = Extension.show,
                .hide = Extension.hide,
            };
        }

        fn redrawUi(plugin: *Self, comptime renderGraphics: RenderGraphicsFn) void {
            if (plugin.gui) |_gui| {
                var arena = std.heap.ArenaAllocator.init(global_allocator);
                defer arena.deinit();

                const arenaAlloc = arena.allocator();
                var ui_events = gui.EventQueue(gui.UiEvent).init(arenaAlloc);
                defer ui_events.deinit();

                _gui.redraw(&ui_events, renderGraphics) catch {
                    @panic("onPosixFd OOM (probably)!");
                };

                plugin.processUiEvents(&ui_events);
            }
        }

        fn createPosixFdSupportExt(comptime renderGraphics: RenderGraphicsFn) clap.plugin_posix_fd_support {
            const Ext = struct {
                fn on_fd(self: *const clap.plugin, fd: i32, flags: clap.clap_posix_fd_flags_t) callconv(.C) void {
                    _ = flags;
                    _ = fd;
                    const plugin = unwrapPluginData(self);
                    redrawUi(plugin, renderGraphics);
                }
            };

            return clap.plugin_posix_fd_support{
                .on_fd = Ext.on_fd,
            };
        }

        fn createTimerExt(comptime renderGraphics: RenderGraphicsFn) clap.plugin_timer_support {
            const Ext = struct {
                fn on_timer(self: *const clap.plugin, id: clap.id) callconv(.C) void {
                    _ = id;
                    const plugin = unwrapPluginData(self);
                    redrawUi(plugin, renderGraphics);
                }
            };

            return clap.plugin_timer_support{ .on_timer = Ext.on_timer };
        }
    };
}
