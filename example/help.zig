const std = @import("std");
const zargs = @import("zargs");

pub fn main() !void {
    const option_descs = comptime [_]zargs.OptionDescription{
        .{ .name = "help", .short_flag = 'h' },
    };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const std_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, std_args);

    const args = try zargs.parseArgs(std_args, &option_descs, .{});

    if (args.opt.help) {
        std.debug.print("You requested help, but I've got none...\n", .{});
        return;
    }

    std.debug.print("Hello!\n", .{});
}
