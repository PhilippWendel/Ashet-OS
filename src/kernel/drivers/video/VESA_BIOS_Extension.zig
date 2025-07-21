const std = @import("std");
const ashet = @import("../../main.zig");
const logger = std.log.scoped(.vbe);

const x86 = ashet.ports.platforms.x86;
const VESA_BIOS_Extension = @This();
const Driver = ashet.drivers.Driver;
const Color = ashet.abi.Color;
const Resolution = ashet.abi.Size;

const multiboot = x86.multiboot;
const vbe = @import("x86/vbe.zig");

const Memory_Mapped_Framebuffer = @import("Memory_Mapped_Framebuffer.zig");

pub fn init(allocator: std.mem.Allocator, mbinfo: *multiboot.Info) !Memory_Mapped_Framebuffer {
    if (!mbinfo.flags.vbe)
        return error.VBE_Unsupported;

    const vbe_info = mbinfo.vbe;

    const vbe_control: *vbe.Control = @ptrFromInt(vbe_info.control_info);
    x86.vmm.ensure_accessible_obj(vbe_control);

    if (vbe_control.signature != vbe.Control.expected_signature)
        @panic("invalid vbe signature!");

    // logger.info("vbe_control = {}", .{vbe_control});

    x86.vmm.ensure_accessible_obj(&vbe_control.oemstring.get()[0]);
    x86.vmm.ensure_accessible_obj(&vbe_control.oem_vendor_name.get()[0]);
    x86.vmm.ensure_accessible_obj(&vbe_control.oem_product_name.get()[0]);
    x86.vmm.ensure_accessible_obj(&vbe_control.oem_product_rev.get()[0]);

    logger.info("  oemstring = '{s}'", .{std.mem.sliceTo(vbe_control.oemstring.get(), 0)});
    logger.info("  oem_vendor_name = '{s}'", .{std.mem.sliceTo(vbe_control.oem_vendor_name.get(), 0)});
    logger.info("  oem_product_name = '{s}'", .{std.mem.sliceTo(vbe_control.oem_product_name.get(), 0)});
    logger.info("  oem_product_rev = '{s}'", .{std.mem.sliceTo(vbe_control.oem_product_rev.get(), 0)});

    {
        logger.info("  video modes:", .{});
        var modes = vbe_control.mode_ptr.get();

        while (true) {
            x86.vmm.ensure_accessible_obj(&modes[0]);
            if (modes[0] == 0xFFFF)
                break;

            if (findModeByAssignedNumber(modes[0])) |mode| {
                switch (mode) {
                    .text => |tm| logger.info("    - {X:0>4} (text {}x{})", .{ modes[0], tm.columns, tm.rows }),
                    .graphics => |gm| logger.info("    - {X:0>4} (graphics {}x{}, {s})", .{ modes[0], gm.width, gm.height, @tagName(gm.colors) }),
                }
            } else {
                logger.info("    - {X:0>4} (unknown)", .{modes[0]});
            }
            modes += 1;
        }
    }

    const vbe_mode: *vbe.ModeInfo = @ptrFromInt(vbe_info.mode_info);
    x86.vmm.ensure_accessible_obj(vbe_mode);

    if (vbe_mode.memory_model != .direct_color) {
        logger.err("mode_info = {}", .{vbe_mode});
        @panic("VBE mode wasn't properly initialized: invalid color mode");
    }
    if (vbe_mode.number_of_planes != 1) {
        logger.err("mode_info = {}", .{vbe_mode});
        @panic("VBE mode wasn't properly initialized: more than 1 plane");
    }
    if (vbe_mode.bits_per_pixel != 32) {
        logger.err("mode_info = {}", .{vbe_mode});
        @panic("VBE mode wasn't properly initialized: expected 32 bpp");
    }

    logger.info("video resolution: {}x{}", .{ vbe_mode.x_resolution, vbe_mode.y_resolution });
    logger.info("video memory:     {}K", .{64 * vbe_control.ram_size});

    return try Memory_Mapped_Framebuffer.create(allocator, "VESA VBE Framebuffer", .{
        .scanline0 = vbe_mode.phys_base_ptr,
        .width = vbe_mode.x_resolution,
        .height = vbe_mode.y_resolution,

        .bits_per_pixel = vbe_mode.bits_per_pixel,
        .bytes_per_scan_line = vbe_mode.lin_bytes_per_scan_line,

        .red_mask_size = vbe_mode.lin_red_mask_size,
        .green_mask_size = vbe_mode.lin_green_mask_size,
        .blue_mask_size = vbe_mode.lin_blue_mask_size,

        .red_shift = vbe_mode.lin_red_field_position,
        .green_shift = vbe_mode.lin_green_field_position,
        .blue_shift = vbe_mode.lin_blue_field_position,
    });
}

const ColorDepth = enum {
    @"16",
    @"256",
    @"1:5:5:5",
    @"5:6:5",
    @"8:8:8",
};

const Mode = union(enum) {
    text: struct {
        rows: u8,
        columns: u8,
    },
    graphics: struct {
        width: u16,
        height: u16,
        colors: ColorDepth,
    },
};

fn textMode(c: u8, r: u8) Mode {
    return .{ .text = .{ .rows = r, .columns = c } };
}

fn graphicsMode(w: u16, h: u16, c: ColorDepth) Mode {
    return .{ .graphics = .{ .width = w, .height = h, .colors = c } };
}

const KnownMode = struct {
    assigned_number: u16,
    mode: Mode,
};

fn knownMode(an: u16, mode: Mode) KnownMode {
    return .{ .assigned_number = an, .mode = mode };
}

fn findModeByAssignedNumber(an: u16) ?Mode {
    return for (known_modes) |kn| {
        if (kn.assigned_number == an)
            break kn.mode;
    } else null;
}

pub const known_modes = [_]KnownMode{
    knownMode(0x100, graphicsMode(640, 400, .@"256")),
    knownMode(0x101, graphicsMode(640, 480, .@"256")),
    knownMode(0x102, graphicsMode(800, 600, .@"16")),
    knownMode(0x103, graphicsMode(800, 600, .@"256")),
    knownMode(0x104, graphicsMode(1024, 768, .@"16")),
    knownMode(0x105, graphicsMode(1024, 768, .@"256")),
    knownMode(0x106, graphicsMode(1280, 1024, .@"16")),
    knownMode(0x107, graphicsMode(1280, 1024, .@"256")),
    knownMode(0x108, textMode(80, 60)),
    knownMode(0x109, textMode(132, 25)),
    knownMode(0x10A, textMode(132, 43)),
    knownMode(0x10B, textMode(132, 50)),
    knownMode(0x10C, textMode(132, 60)),
    knownMode(0x10D, graphicsMode(320, 200, .@"1:5:5:5")),
    knownMode(0x10E, graphicsMode(320, 200, .@"5:6:5")),
    knownMode(0x10F, graphicsMode(320, 200, .@"8:8:8")),
    knownMode(0x110, graphicsMode(640, 480, .@"1:5:5:5")),
    knownMode(0x111, graphicsMode(640, 480, .@"5:6:5")),
    knownMode(0x112, graphicsMode(640, 480, .@"8:8:8")),
    knownMode(0x113, graphicsMode(800, 600, .@"1:5:5:5")),
    knownMode(0x114, graphicsMode(800, 600, .@"5:6:5")),
    knownMode(0x115, graphicsMode(800, 600, .@"8:8:8")),
    knownMode(0x116, graphicsMode(1024, 768, .@"1:5:5:5")),
    knownMode(0x117, graphicsMode(1024, 768, .@"5:6:5")),
    knownMode(0x118, graphicsMode(1024, 768, .@"8:8:8")),
    knownMode(0x119, graphicsMode(1280, 1024, .@"1:5:5:5")),
    knownMode(0x11A, graphicsMode(1280, 1024, .@"5:6:5")),
    knownMode(0x11B, graphicsMode(1280, 1024, .@"8:8:8")),
};
