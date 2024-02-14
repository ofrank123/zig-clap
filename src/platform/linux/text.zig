const std = @import("std");
const gui = @import("gui_shared");

const dlog = std.log.debug;

const c = @cImport({
    @cInclude("freetype/ftadvanc.h");
    @cInclude("freetype/ftbbox.h");
    @cInclude("freetype/ftbitmap.h");
    @cInclude("freetype/ftcolor.h");
    @cInclude("freetype/ftlcdfil.h");
    @cInclude("freetype/ftsizes.h");
    @cInclude("freetype/ftstroke.h");
    @cInclude("freetype/fttrigon.h");
    @cInclude("freetype/ftsynth.h");
});

const FontError = error{
    ResourceCreateFailed,
    CharacterLoadError,
};

pub fn drawGlyph(
    bitmap: *gui.Bitmap,
    glyph: *c.FT_Bitmap,
    x: c.FT_Int,
    y: c.FT_Int,
) void {
    var x_max: usize = @as(usize, @intCast(x)) + glyph.width;
    var y_max: usize = @as(usize, @intCast(y)) + glyph.rows;

    for (@as(usize, @intCast(x))..x_max, 0..) |i, p| {
        for (@as(usize, @intCast(y))..y_max, 0..) |j, q| {
            if (i < 0 or i >= bitmap.width or
                j < 0 or j >= bitmap.height)
            {
                continue;
            }

            const color_bw: u8 = @intCast(glyph.buffer[q * glyph.width + p]);
            var color: gui.Color = .{ .c = .{
                .r = color_bw,
                .g = color_bw,
                .b = color_bw,
                .a = color_bw,
            } };
            bitmap.set(.{ .x = i, .y = j }, color);
        }
    }
}

pub fn init(
    font_data: []const u8,
    bitmap: *gui.Bitmap,
) !void {
    const text = "Hello World!";

    var ft_error: c.FT_Error = 0;

    var ft_library: c.FT_Library = undefined;
    ft_error = c.FT_Init_FreeType(&ft_library);
    errdefer _ = c.FT_Done_FreeType(ft_library);
    if (ft_error != 0) {
        return FontError.ResourceCreateFailed;
    }

    var ft_face: c.FT_Face = undefined;
    ft_error = c.FT_New_Memory_Face(
        ft_library,
        font_data.ptr,
        @intCast(font_data.len),
        0,
        &ft_face,
    );
    errdefer _ = c.FT_Done_Face(ft_face);
    if (ft_error != 0) {
        return FontError.ResourceCreateFailed;
    }

    ft_error = c.FT_Set_Char_Size(ft_face, 48 * 64, 0, 100, 0);

    var ft_slot: c.FT_GlyphSlot = ft_face.*.glyph;

    var pen_x: usize = 10;
    var pen_y: usize = 100;

    for (0..text.len) |n| {
        ft_error = c.FT_Load_Char(ft_face, text[n], c.FT_LOAD_RENDER);
        if (ft_error != 0) {
            return FontError.CharacterLoadError;
        }

        drawGlyph(
            bitmap,
            &ft_slot.*.bitmap,
            @as(c.FT_Int, @intCast(pen_x)) + ft_slot.*.bitmap_left,
            @as(c.FT_Int, @intCast(pen_y)) - ft_slot.*.bitmap_top,
        );

        pen_x += @intCast(ft_slot.*.advance.x >> 6);
    }
}
