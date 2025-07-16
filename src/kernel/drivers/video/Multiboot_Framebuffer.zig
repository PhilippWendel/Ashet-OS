const std = @import("std");
const ashet = @import("../../main.zig");
const logger = std.log.scoped(.vbe);

const x86 = ashet.ports.platforms.x86;
const Multiboot_Framebuffer = @This();
const Driver = ashet.drivers.Driver;
const Color = ashet.abi.Color;
const Resolution = ashet.abi.Size;

const multiboot = x86.multiboot;
const Memory_Mapped_Framebuffer = @import("Memory_Mapped_Framebuffer.zig");

pub fn init(allocator: std.mem.Allocator, mbinfo: *multiboot.Info) !Memory_Mapped_Framebuffer {
    if (!mbinfo.flags.framebuffer)
        return error.NoMultibootFramebuffer;

    const fb = mbinfo.framebuffer;

    switch (fb.type) {
        .rgb => {},
        .indexed, .text => return error.UnsupportedMode,
        _ => return error.UnsupportedMode,
    }

    const color_info = fb.color_info.rgb;

    logger.info("fb resolution: {}x{} pixels", .{ fb.width, fb.height });
    logger.info("fb pitch:      {} byte", .{fb.pitch});
    logger.info("fb depth:      {} bits", .{fb.bpp});
    logger.info("fb color info:", .{});
    logger.info("  red:   {}/+{}", .{ color_info.red_field_position, color_info.red_mask_size });
    logger.info("  green: {}/+{}", .{ color_info.green_field_position, color_info.green_mask_size });
    logger.info("  blue:  {}/+{}", .{ color_info.blue_field_position, color_info.blue_mask_size });

    return .create(allocator, "Multiboot Framebuffer", .{
        .scanline0 = @ptrFromInt(@as(usize, @intCast(fb.address))),
        .width = fb.width,
        .height = fb.height,

        .bits_per_pixel = fb.bpp,
        .bytes_per_scan_line = fb.pitch,

        .red_mask_size = color_info.red_mask_size,
        .green_mask_size = color_info.green_mask_size,
        .blue_mask_size = color_info.blue_mask_size,

        .red_shift = color_info.red_field_position,
        .green_shift = color_info.green_field_position,
        .blue_shift = color_info.blue_field_position,
    });
}
