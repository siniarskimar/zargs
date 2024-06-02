const std = @import("std");
const testing = std.testing;

pub const OptionDescription = struct {
    name: [:0]const u8,
    short_flag: ?u8 = null,
    value_type: type = void,
    help: ?[]const u8 = null,
    occurences: enum { single, multiple } = .single,
};

pub const PositionalDescription = struct {
    name: [:0]const u8,
    value_type: type = []const u8,
};

fn OptionFieldType(comptime OptionValueType: type) type {
    return switch (OptionValueType) {
        void => bool,
        else => if (@typeInfo(OptionValueType) == .Optional)
            @compileError("Options cannot have optional value_type as they are optional by default")
        else
            ?OptionValueType,
    };
}

fn OptionField(comptime desc: OptionDescription) std.builtin.Type.StructField {
    const field_type = OptionFieldType(desc.value_type);
    return std.builtin.Type.StructField{
        .name = desc.name,
        .type = field_type,
        .default_value = if (desc.value_type == void) &@as(bool, false) else &@as(field_type, null),
        .is_comptime = false,
        .alignment = @alignOf(field_type),
    };
}

fn PositionalField(comptime desc: PositionalDescription) std.builtin.Type.StructField {
    return std.builtin.Type.StructField{
        .name = desc.name,
        .type = desc.value_type,
        .default_value = if (@typeInfo(desc.value_type) == .Optional) &@as(desc.value_type, null) else &@as(desc.value_type, undefined),
        .is_comptime = false,
        .alignment = @alignOf(desc.value_type),
    };
}

pub fn Arguments(
    comptime option_descs: []const OptionDescription,
    comptime positionals_descs: []const PositionalDescription,
) type {
    var positional_fields: [positionals_descs.len]std.builtin.Type.StructField = undefined;
    var option_fields: [option_descs.len]std.builtin.Type.StructField = undefined;

    for (option_descs, 0..) |desc, idx| {
        option_fields[idx] = OptionField(desc);
    }

    var has_optional_positionals = false;
    for (positionals_descs, 0..) |desc, idx| {
        positional_fields[idx] = PositionalField(desc);
        if (@typeInfo(desc.value_type) == .Optional) {
            if (has_optional_positionals) {
                @compileError("All positionals following optional positional must be also optional");
            } else {
                has_optional_positionals = true;
            }
        }
    }

    const OptNamespace = @Type(.{ .Struct = std.builtin.Type.Struct{
        .layout = .auto,
        .fields = &option_fields,
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_tuple = false,
    } });

    const PosNamespace = @Type(.{ .Struct = std.builtin.Type.Struct{
        .layout = .auto,
        .fields = &positional_fields,
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_tuple = false,
    } });

    return @Type(.{ .Struct = std.builtin.Type.Struct{
        .layout = .auto,
        .fields = &[_]std.builtin.Type.StructField{
            std.builtin.Type.StructField{
                .name = "opt",
                .type = OptNamespace,
                .default_value = &OptNamespace{},
                .is_comptime = false,
                .alignment = @alignOf(OptNamespace),
            },
            std.builtin.Type.StructField{
                .name = "pos",
                .type = PosNamespace,
                .default_value = &PosNamespace{},
                .is_comptime = false,
                .alignment = @alignOf(PosNamespace),
            },
            std.builtin.Type.StructField{
                .name = "stop_index",
                .type = usize,
                .default_value = &@as(usize, 0),
                .is_comptime = false,
                .alignment = @alignOf(usize),
            },
            std.builtin.Type.StructField{
                .name = "last_pos_index",
                .type = usize,
                .default_value = &@as(usize, 0),
                .is_comptime = false,
                .alignment = @alignOf(usize),
            },
        },
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_tuple = false,
    } });
}

fn parseArgumentValue(
    comptime ArgType: type,
    comptime T: type,
    str: ?[]const u8,
) !switch (ArgType) {
    PositionalDescription => T,
    OptionDescription => OptionFieldType(T),
    else => @compileError("Unsupported type"),
} {
    switch (@typeInfo(T)) {
        .Optional => if (str) |value_slice| {
            const child_type = std.meta.Child(T);
            return try parseArgumentValue(ArgType, child_type, value_slice);
        } else {
            return null;
        },
        .Array => @compileError("Arrays of values are unsupported"),
        .Int => {
            const value_slice = str orelse return error.MissingValue;
            return try std.fmt.parseInt(T, value_slice, 0);
        },
        .Float => {
            const value_slice = str orelse return error.MissingValue;
            return try std.fmt.parseFloat(T, value_slice);
        },
        .Void => {
            return true;
        },
        .Bool => {
            const value_slice = str orelse return error.MissingValue;

            if (std.mem.eql(u8, value_slice, "true"))
                return true
            else if (std.mem.eql(u8, value_slice, "false"))
                return false
            else
                return error.InvalidValue;
        },
        .Enum => {
            const value_slice = str orelse return error.MissingValue;
            return std.meta.stringToEnum(T, value_slice) orelse error.InvalidValue;
        },
        .Pointer => |typeinfo| if (typeinfo.size == .Slice and typeinfo.is_const and typeinfo.child == u8) {
            return str orelse error.MissingValue;
        } else @compileError("Use usize instead of pointer type to represent pointers"),

        else => @compileError("Unsupported type " ++ @typeName(T)),
    }
}

pub fn parseArgs(
    args: []const []const u8,
    comptime option_descs: []const OptionDescription,
    options: struct {
        // Already comptime as PositionalDescription has comptime field
        positional_descs: []const PositionalDescription = &[_]PositionalDescription{},
        pause_token: ?[]const u8 = null,
    },
) !Arguments(option_descs, options.positional_descs) {
    var result: Arguments(option_descs, options.positional_descs) = .{};

    var arg_idx: usize = 0;
    var positional_idx: usize = 0;
    const req_positional_count: usize = blk: {
        var count: usize = 0;
        inline for (options.positional_descs) |desc| {
            if (@typeInfo(desc.value_type) != .Optional) {
                count += 1;
            }
        }

        break :blk count;
    };

    while (arg_idx < args.len) {
        const arg = args[arg_idx];
        if (arg.len == 0) unreachable;
        if (options.pause_token) |token| if (std.mem.eql(u8, arg, token)) {
            result.stop_index = arg_idx;
            break;
        };

        if (arg.len > 2 and (std.mem.startsWith(u8, arg, "--") or arg[0] == '-')) {
            // Long option
            const name_start: usize = if (arg[0] == '-' and arg[1] == '-') 2 else 1;
            const name_end = std.mem.indexOfScalar(u8, arg, '=') orelse arg.len;
            const arg_name = arg[name_start..name_end];

            inline for (option_descs) |desc| {
                if (std.mem.eql(u8, desc.name, arg_name)) {
                    const maybe_value_slice: ?[]const u8 = if (name_end != arg.len)
                        arg[name_end + 1 ..]
                    else if (arg_idx + 1 < args.len)
                        args[arg_idx + 1]
                    else
                        null;

                    @field(result.opt, desc.name) = try parseArgumentValue(OptionDescription, desc.value_type, maybe_value_slice);

                    if (desc.value_type != void and name_end == arg.len) {
                        arg_idx += 1;
                    }
                    break;
                }
            }
        } else if (arg.len == 2 and arg[0] == '-') {
            // Short flag
            inline for (option_descs) |desc| if (desc.short_flag) |flag| {
                if (flag == arg[1]) {
                    const maybe_value_slice: ?[]const u8 = if (arg_idx + 1 < args.len)
                        args[arg_idx + 1]
                    else
                        null;

                    @field(result.opt, desc.name) = try parseArgumentValue(OptionDescription, desc.value_type, maybe_value_slice);

                    if (desc.value_type != void) {
                        arg_idx += 1;
                    }
                    break;
                }
            };
        } else {
            // Positional
            inline for (options.positional_descs, 0..) |desc, idx| {
                if (positional_idx == idx) {
                    @field(result.pos, desc.name) = try parseArgumentValue(PositionalDescription, desc.value_type, arg);
                    result.last_pos_index = arg_idx;
                    positional_idx += 1;
                    break;
                }
            }
        }
        arg_idx += 1;
    }

    if (positional_idx < req_positional_count) return error.ExpectedPositional;

    return result;
}

pub fn formatHelp(
    comptime option_descs: []OptionDescription,
    comptime positional_descs: []PositionalDescription,
    column_width: usize,
) []const u8 {
    _ = option_descs;
    _ = positional_descs;
    _ = column_width;
}

test "parseArgs" {
    const option_descs = comptime [_]OptionDescription{
        .{ .name = "number", .short_flag = 'n', .value_type = i32 },
        .{ .name = "float", .short_flag = 'f', .value_type = f32 },
        .{ .name = "str", .short_flag = 's', .value_type = []const u8 },
        .{ .name = "bool", .short_flag = 'b', .value_type = bool },
        .{ .name = "flag", .short_flag = 'F' },
    };
    const Command = enum { status, get };

    const positional_descs = comptime [_]PositionalDescription{
        .{ .name = "command", .value_type = Command },
        .{ .name = "optional", .value_type = ?[]const u8 },
    };

    const cases = [_]struct {
        args: []const []const u8,
        expected: Arguments(&option_descs, &[_]PositionalDescription{}),
    }{
        .{
            .args = &[_][]const u8{ "--number", "48" },
            .expected = .{ .opt = .{ .number = 48 } },
        },
        .{
            .args = &[_][]const u8{"--number=48"},
            .expected = .{ .opt = .{ .number = 48 } },
        },
        .{
            .args = &[_][]const u8{"-number=48"},
            .expected = .{ .opt = .{ .number = 48 } },
        },
        .{
            .args = &[_][]const u8{ "-n", "48" },
            .expected = .{ .opt = .{ .number = 48 } },
        },
        .{
            .args = &[_][]const u8{ "-f", "69.420" },
            .expected = .{ .opt = .{ .float = 69.420 } },
        },
        .{
            .args = &[_][]const u8{ "-s", "never gonna give you up" },
            .expected = .{ .opt = .{ .str = "never gonna give you up" } },
        },
    };

    const positional_cases = [_]struct {
        args: []const []const u8,
        expected: Arguments(&option_descs, &positional_descs),
    }{ .{
        .args = &[_][]const u8{"get"},
        .expected = .{ .pos = .{ .command = .get } },
    }, .{
        .args = &[_][]const u8{ "get", "lucky" },
        .expected = .{ .pos = .{ .command = .get, .optional = "lucky" } },
    } };

    for (cases[0 .. cases.len - 1]) |case| {
        const args = try parseArgs(case.args, &option_descs, .{});
        try testing.expectEqual(case.expected, args);
    }

    {
        // std.testing.expectEqual for []const u8 tests pointer and
        // length equality but not content equality
        const case = cases[cases.len - 1 - 0];

        const args = try parseArgs(case.args, &option_descs, .{});
        try testing.expect(args.opt.str != null);
        try testing.expectEqualSlices(u8, case.expected.opt.str.?, args.opt.str.?);
    }

    for (positional_cases[0 .. positional_cases.len - 1]) |case| {
        const args = try parseArgs(case.args, &option_descs, .{ .positional_descs = &positional_descs });
        try testing.expectEqual(case.expected, args);
    }

    {
        // std.testing.expectEqual for []const u8 tests pointer and
        // length equality but not content equality
        const case = positional_cases[positional_cases.len - 1 - 0];

        const args = try parseArgs(case.args, &option_descs, .{ .positional_descs = &positional_descs });
        try testing.expect(args.pos.optional != null);
        try testing.expectEqualSlices(u8, case.expected.pos.optional.?, args.pos.optional.?);
    }
}

test {
    _ = testing.refAllDecls(@This());
}

test "subcommands" {
    const Command = enum { add, status };
    const CommandItems = enum { task, issue };

    const pos_descs = comptime [_]PositionalDescription{
        .{ .name = "command", .value_type = Command },
    };

    const add_descs = comptime [_]PositionalDescription{
        .{ .name = "item", .value_type = CommandItems },
    };

    const status_descs = comptime [_]PositionalDescription{
        .{ .name = "item", .value_type = ?CommandItems },
    };

    const positional_cases = [_]struct {
        args: []const []const u8,
        expected_main: Arguments(&.{}, &pos_descs),
        expected_add: Arguments(&.{}, &add_descs),
        expected_status: Arguments(&.{}, &status_descs),
    }{ .{
        .args = &[_][]const u8{ "add", "task" },
        .expected_main = .{ .pos = .{ .command = Command.add } },
        .expected_add = .{ .pos = .{ .item = CommandItems.task } },
        .expected_status = .{},
    }, .{
        .args = &[_][]const u8{ "status", "task" },
        .expected_main = .{ .pos = .{ .command = Command.status } },
        .expected_add = .{},
        .expected_status = .{ .pos = .{ .item = CommandItems.task } },
    }, .{
        .args = &[_][]const u8{"status"},
        .expected_main = .{ .pos = .{ .command = Command.status } },
        .expected_add = .{},
        .expected_status = .{},
    } };

    for (positional_cases) |case| {
        const args = try parseArgs(case.args, &.{}, .{ .positional_descs = &pos_descs });

        try testing.expectEqual(case.expected_main, args);

        switch (args.pos.command) {
            .add => {
                const subargs = try parseArgs(case.args[args.last_pos_index + 1 ..], &.{}, .{ .positional_descs = &add_descs });
                try testing.expectEqual(case.expected_add, subargs);
            },
            .status => {
                const subargs = try parseArgs(case.args[args.last_pos_index + 1 ..], &.{}, .{ .positional_descs = &status_descs });
                try testing.expectEqual(case.expected_status, subargs);
            },
        }
    }
}
