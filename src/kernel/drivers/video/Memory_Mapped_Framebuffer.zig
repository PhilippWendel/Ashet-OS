//!
//! Framebuffer Mapping Utility
//!
//! Implements functions to convert the internal format into arbitrary RGB framebuffers.
//!
const std = @import("std");
const ashet = @import("../../main.zig");

const logger = std.log.scoped(.fbmapped);

const Driver = ashet.drivers.Driver;
const Color = ashet.abi.Color;
const Resolution = ashet.abi.Size;

const Memory_Mapped_Framebuffer = @This();

driver: Driver,

framebuffer: Framebuffer,

backing_buffer: []align(ashet.memory.page_size) Color,
border_color: Color = ashet.video.defaults.border_color,

pub fn create(allocator: std.mem.Allocator, driver_name: []const u8, config: Config) !Memory_Mapped_Framebuffer {
    const framebuffer = try config.instantiate();

    ashet.memory.protection.ensure_accessible_slice(framebuffer.base[0 .. framebuffer.height * framebuffer.stride]);

    for (framebuffer.base[0 .. framebuffer.height * framebuffer.stride]) |_| {
        //
    }

    const vmem = try allocator.alignedAlloc(Color, ashet.memory.page_size, framebuffer.width * framebuffer.height);
    errdefer allocator.free(vmem);

    @memset(vmem, ashet.video.defaults.border_color);
    ashet.video.load_splash_screen(.{
        .base = vmem.ptr,
        .width = @intCast(framebuffer.width),
        .height = @intCast(framebuffer.height),
        .stride = framebuffer.width,
    });

    var driver = Memory_Mapped_Framebuffer{
        .driver = .{
            .name = driver_name,
            .class = .{
                .video = .{
                    .flush_fn = flush,
                    .get_properties_fn = get_properties,
                },
            },
        },

        .framebuffer = framebuffer,

        .backing_buffer = vmem,
    };

    flush(&driver.driver);

    return driver;
}

pub const RGB = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    x: u8,
};

pub const Framebuffer = struct {
    const WriteFn = fn (ptr: [*]u8, color: RGB) void;

    writeFn: *const WriteFn,
    base: [*]u8,
    stride: usize,
    width: u32,
    height: u32,
    byte_per_pixel: u32,
};

pub const Config = struct {
    scanline0: [*]u8,
    width: u32,
    height: u32,

    bits_per_pixel: u32,
    bytes_per_scan_line: u32,

    red_mask_size: u32,
    green_mask_size: u32,
    blue_mask_size: u32,

    red_shift: u32,
    green_shift: u32,
    blue_shift: u32,

    pub fn instantiate(cfg: Config) error{Unsupported}!Framebuffer {
        errdefer logger.warn("unsupported framebuffer configuration: {}", .{cfg});

        // special case for
        if (cfg.red_mask_size == 0 and
            cfg.green_mask_size == 0 and
            cfg.blue_mask_size == 0 and
            cfg.red_shift == 0 and
            cfg.green_shift == 0 and
            cfg.blue_shift == 0 and
            cfg.bytes_per_scan_line == 0 and
            cfg.bits_per_pixel == 32)
        {
            // Assume the following device:
            // oemstring = 'S3 Incorporated. Twister BIOS'
            // oem_vendor_name = 'S3 Incorporated.'
            // oem_product_name = 'VBE 2.0'
            // oem_product_rev = 'Rev 1.1'

            return Framebuffer{
                .writeFn = buildSpecializedWriteFunc8(u32, 16, 8, 0), // RGBX32

                .base = cfg.scanline0,

                .stride = 4 * cfg.width,
                .width = cfg.width,
                .height = cfg.height,

                .byte_per_pixel = @divExact(cfg.bits_per_pixel, 8),
            };
        }

        const channel_depth_8bit = (cfg.red_mask_size == 8 and cfg.green_mask_size == 8 and cfg.blue_mask_size == 8);
        if (!channel_depth_8bit)
            return error.Unsupported;

        const write_ptr = switch (cfg.bits_per_pixel) {
            32 => if (cfg.red_shift == 0 and cfg.green_shift == 8 and cfg.blue_shift == 16)
                buildSpecializedWriteFunc8(u32, 0, 8, 16) // XBGR32
            else if (cfg.red_shift == 16 and cfg.green_shift == 8 and cfg.blue_shift == 0)
                buildSpecializedWriteFunc8(u32, 16, 8, 0) // XRGB32
            else if (cfg.red_shift == 8 and cfg.green_shift == 16 and cfg.blue_shift == 24)
                buildSpecializedWriteFunc8(u32, 8, 16, 24) // BGRX32
            else if (cfg.red_shift == 24 and cfg.green_shift == 16 and cfg.blue_shift == 8)
                buildSpecializedWriteFunc8(u32, 24, 16, 8) // RGBX32
            else
                return error.Unsupported,

            24 => if (cfg.red_shift == 0 and cfg.green_shift == 8 and cfg.blue_shift == 16)
                buildSpecializedWriteFunc8(u24, 0, 8, 16) // BGR24
            else if (cfg.red_shift == 16 and cfg.green_shift == 8 and cfg.blue_shift == 0)
                buildSpecializedWriteFunc8(u24, 16, 8, 0) // RGB24
            else
                return error.Unsupported,

            // 16 => if (cfg.red_shift == 0 and cfg.green_shift == 5 and cfg.blue_shift == 11)
            //     buildSpecializedWriteFunc32(u16, 0, 5, 11) // RGB565
            // else if (cfg.red_shift == 11 and cfg.green_shift == 5 and cfg.blue_shift == 0)
            //     buildSpecializedWriteFunc32(u16, 11, 5, 0) // BGR565
            // else
            //     return error.Unsupported,

            else => return error.Unsupported,
        };

        return Framebuffer{
            .writeFn = write_ptr,

            .base = cfg.scanline0,

            .stride = cfg.bytes_per_scan_line,
            .width = cfg.width,
            .height = cfg.height,

            .byte_per_pixel = @divExact(cfg.bits_per_pixel, 8),
        };
    }

    pub fn buildSpecializedWriteFunc8(comptime Pixel: type, comptime rshift: u32, comptime gshift: u32, comptime bshift: u32) *const Framebuffer.WriteFn {
        return struct {
            fn write(ptr: [*]u8, rgb: RGB) void {
                @setRuntimeSafety(false);
                const color: Pixel = (@as(Pixel, rgb.r) << rshift) |
                    (@as(Pixel, rgb.g) << gshift) |
                    (@as(Pixel, rgb.b) << bshift);
                std.mem.writeInt(Pixel, ptr[0 .. (@typeInfo(Pixel).int.bits + 7) / 8], color, .little);
            }
        }.write;
    }
};

fn get_properties(driver: *Driver) ashet.video.DeviceProperties {
    const vd: *Memory_Mapped_Framebuffer = @fieldParentPtr("driver", driver);
    return .{
        .resolution = .{
            .width = @intCast(vd.framebuffer.width),
            .height = @intCast(vd.framebuffer.height),
        },
        .stride = vd.framebuffer.width,
        .video_memory = vd.backing_buffer,
        .video_memory_mapping = .buffered,
    };
}

fn flush(driver: *Driver) void {
    const vd: *Memory_Mapped_Framebuffer = @fieldParentPtr("driver", driver);

    @setRuntimeSafety(false);
    // const flush_time_start = readHwCounter();

    const pixel_count = @as(usize, vd.framebuffer.width) * @as(usize, vd.framebuffer.height);

    {
        var row = vd.framebuffer.base;
        var ind: usize = 0;

        var x: usize = 0;
        for (vd.backing_buffer[0..pixel_count]) |color| {
            vd.framebuffer.writeFn(row + ind, pal(color));

            x += 1;
            ind += vd.framebuffer.byte_per_pixel;

            if (x == vd.framebuffer.width) {
                x = 0;
                ind = 0;
                row += vd.framebuffer.stride;
            }
        }
    }

    // const flush_time_end = readHwCounter();
    // const flush_time = flush_time_end -| flush_time_start;

    // flush_limit += flush_time;
    // flush_count += 1;

    // logger.debug("frame flush time: {} cycles, avg {} cycles", .{ flush_time, flush_limit / flush_count });
}

inline fn pal(color: Color) RGB {
    @setRuntimeSafety(false);
    const rgb = color.to_rgb888();
    return .{
        .r = rgb.r,
        .g = rgb.g,
        .b = rgb.b,
        .x = 0,
    };
}
