const std = @import("std");

const config = @import("config.zig");
const marketplace_config = @import("marketplace_config.zig");

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const subcommand = args.next() orelse {
        printHelp();
        return error.MissingPluginSubcommand;
    };
    if (isHelpFlag(subcommand)) {
        printHelp();
        return;
    }
    if (std.mem.eql(u8, subcommand, "marketplace")) {
        try runMarketplace(allocator, args);
        return;
    }
    return error.UnknownPluginSubcommand;
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig plugin marketplace <COMMAND>
        \\
        \\Subcommands:
        \\  marketplace       Manage plugin marketplaces
        \\
        \\Marketplace behavior is parsed but not implemented yet.
        \\
    , .{});
}

fn runMarketplace(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const subcommand = args.next() orelse {
        printMarketplaceHelp();
        return error.MissingPluginMarketplaceSubcommand;
    };
    if (isHelpFlag(subcommand)) {
        printMarketplaceHelp();
        return;
    }
    if (std.mem.eql(u8, subcommand, "add")) {
        try runMarketplaceAdd(allocator, args);
        return;
    }
    if (std.mem.eql(u8, subcommand, "upgrade")) {
        try runMarketplaceUpgrade(args);
        return;
    }
    if (std.mem.eql(u8, subcommand, "remove")) {
        try runMarketplaceRemove(allocator, args);
        return;
    }
    return error.UnknownPluginMarketplaceSubcommand;
}

fn runMarketplaceAdd(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var source: ?[]const u8 = null;
    var ref_name: ?[]const u8 = null;
    var sparse_paths = std.ArrayList([]const u8).empty;
    defer sparse_paths.deinit(allocator);

    while (args.next()) |arg| {
        if (isHelpFlag(arg)) {
            printMarketplaceAddHelp();
            return;
        }
        if (std.mem.eql(u8, arg, "--ref")) {
            const value = args.next() orelse return error.MissingPluginMarketplaceRef;
            if (value.len == 0) return error.MissingPluginMarketplaceRef;
            ref_name = value;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ref=")) {
            const value = arg["--ref=".len..];
            if (value.len == 0) return error.MissingPluginMarketplaceRef;
            ref_name = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--sparse")) {
            const value = args.next() orelse return error.MissingPluginMarketplaceSparsePath;
            if (value.len == 0) return error.MissingPluginMarketplaceSparsePath;
            try sparse_paths.append(allocator, value);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sparse=")) {
            const value = arg["--sparse=".len..];
            if (value.len == 0) return error.MissingPluginMarketplaceSparsePath;
            try sparse_paths.append(allocator, value);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownPluginMarketplaceAddOption;
        if (source != null) return error.UnexpectedPluginMarketplaceArgument;
        source = arg;
    }

    const source_value = source orelse {
        printMarketplaceAddHelp();
        return error.MissingPluginMarketplaceSource;
    };
    try addMarketplaceAndPrint(allocator, source_value, ref_name, sparse_paths.items);
}

fn runMarketplaceUpgrade(args: *std.process.Args.Iterator) !void {
    var has_marketplace_name = false;

    while (args.next()) |arg| {
        if (isHelpFlag(arg)) {
            printMarketplaceUpgradeHelp();
            return;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownPluginMarketplaceUpgradeOption;
        if (has_marketplace_name) return error.UnexpectedPluginMarketplaceArgument;
        has_marketplace_name = true;
    }

    return notImplemented("plugin marketplace upgrade");
}

fn runMarketplaceRemove(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const marketplace_name = args.next() orelse {
        printMarketplaceRemoveHelp();
        return error.MissingPluginMarketplaceName;
    };
    if (isHelpFlag(marketplace_name)) {
        printMarketplaceRemoveHelp();
        return;
    }
    if (std.mem.startsWith(u8, marketplace_name, "-")) return error.MissingPluginMarketplaceName;
    if (args.next() != null) return error.UnexpectedPluginMarketplaceArgument;
    try removeMarketplaceAndPrint(allocator, marketplace_name);
}

fn notImplemented(command: []const u8) !void {
    std.debug.print("codex-zig {s} is parsed but not implemented yet\n", .{command});
    return error.PluginCommandNotImplemented;
}

fn addMarketplaceAndPrint(allocator: std.mem.Allocator, source: []const u8, ref_name: ?[]const u8, sparse_paths: []const []const u8) !void {
    const codex_home = try config.resolveCodexHome(allocator);
    defer allocator.free(codex_home);
    const config_path = try config.configTomlPath(allocator, codex_home);
    defer allocator.free(config_path);
    const config_bytes = try config.readConfigTomlFile(allocator, config_path);
    defer if (config_bytes) |bytes| allocator.free(bytes);

    const add = marketplace_config.addLocalMarketplace(allocator, config_bytes orelse "", source, ref_name, sparse_paths) catch |err| {
        try printAddError(allocator, err);
        return err;
    };
    defer add.deinit(allocator);
    try config.writeConfigTomlFile(config_path, add.updated_config);

    if (add.already_added) {
        std.debug.print("Marketplace `{s}` is already added from {s}.\n", .{ add.marketplace_name, add.installed_root });
    } else {
        std.debug.print("Added marketplace `{s}` from {s}.\n", .{ add.marketplace_name, add.installed_root });
    }
    std.debug.print("Installed marketplace root: {s}\n", .{add.installed_root});
}

fn removeMarketplaceAndPrint(allocator: std.mem.Allocator, marketplace_name: []const u8) !void {
    const codex_home = try config.resolveCodexHome(allocator);
    defer allocator.free(codex_home);
    const config_path = try config.configTomlPath(allocator, codex_home);
    defer allocator.free(config_path);
    const config_bytes = try config.readConfigTomlFile(allocator, config_path);
    defer if (config_bytes) |bytes| allocator.free(bytes);

    const removed = marketplace_config.removeMarketplace(allocator, codex_home, config_bytes orelse "", marketplace_name) catch |err| {
        try printRemoveError(allocator, marketplace_name, err);
        return err;
    };
    defer removed.deinit(allocator);
    try config.writeConfigTomlFile(config_path, removed.updated_config);

    std.debug.print("Removed marketplace `{s}`.\n", .{removed.marketplace_name});
    if (removed.installed_root) |root| {
        std.debug.print("Removed installed marketplace root: {s}\n", .{root});
    }
}

fn printAddError(allocator: std.mem.Allocator, err: anyerror) !void {
    return switch (err) {
        error.UnsupportedMarketplaceSource => std.debug.print("codex-zig plugin marketplace add is parsed for git sources but not implemented yet\n", .{}),
        error.MarketplaceSourceEmpty => std.debug.print("marketplace source must not be empty\n", .{}),
        error.RefUnsupportedForLocalSource => std.debug.print("--ref is only supported for git marketplace sources\n", .{}),
        error.SparseUnsupportedForLocalSource => std.debug.print("--sparse is only supported for git marketplace sources\n", .{}),
        error.InvalidLocalMarketplaceSource => std.debug.print("failed to resolve local marketplace source path\n", .{}),
        error.LocalMarketplaceSourceMustBeDirectory => std.debug.print("local marketplace source must be a directory, not a file\n", .{}),
        error.InvalidMarketplaceRoot => std.debug.print("invalid marketplace root\n", .{}),
        error.InvalidMarketplaceName => std.debug.print("invalid marketplace name\n", .{}),
        error.ReservedMarketplaceName => std.debug.print("marketplace 'openai-curated' is reserved and cannot be added from this source\n", .{}),
        error.MarketplaceAlreadyAddedDifferentSource => std.debug.print("marketplace is already added from a different source; remove it before adding this source\n", .{}),
        else => {
            const message = try std.fmt.allocPrint(allocator, "failed to add marketplace: {s}\n", .{@errorName(err)});
            defer allocator.free(message);
            std.debug.print("{s}", .{message});
        },
    };
}

fn printRemoveError(allocator: std.mem.Allocator, marketplace_name: []const u8, err: anyerror) !void {
    return switch (err) {
        error.InvalidMarketplaceName => std.debug.print("invalid marketplace name\n", .{}),
        error.UnknownMarketplace => {
            const message = try std.fmt.allocPrint(allocator, "marketplace `{s}` is not configured or installed\n", .{marketplace_name});
            defer allocator.free(message);
            std.debug.print("{s}", .{message});
        },
        else => {
            const message = try std.fmt.allocPrint(allocator, "failed to remove marketplace: {s}\n", .{@errorName(err)});
            defer allocator.free(message);
            std.debug.print("{s}", .{message});
        },
    };
}

fn printMarketplaceHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig plugin marketplace <COMMAND>
        \\
        \\Subcommands:
        \\  add SOURCE          Add a marketplace source
        \\  upgrade [NAME]      Upgrade configured Git marketplaces
        \\  remove NAME         Remove a configured marketplace
        \\
    , .{});
}

fn printMarketplaceAddHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig plugin marketplace add [--ref REF] [--sparse PATH] SOURCE
        \\
        \\SOURCE accepts the Rust CLI forms: owner/repo[@ref], Git URL, SSH URL,
        \\or local marketplace root directory.
        \\
        \\Options:
        \\  --ref REF           Git ref for the marketplace source
        \\  --sparse PATH       Sparse checkout path; repeatable
        \\
    , .{});
}

fn printMarketplaceUpgradeHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig plugin marketplace upgrade [MARKETPLACE_NAME]
        \\
    , .{});
}

fn printMarketplaceRemoveHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig plugin marketplace remove MARKETPLACE_NAME
        \\
    , .{});
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}
