const std = @import("std");

pub fn run(args: *std.process.Args.Iterator) !void {
    const subcommand = args.next() orelse {
        printHelp();
        return error.MissingPluginSubcommand;
    };
    if (isHelpFlag(subcommand)) {
        printHelp();
        return;
    }
    if (std.mem.eql(u8, subcommand, "marketplace")) {
        try runMarketplace(args);
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

fn runMarketplace(args: *std.process.Args.Iterator) !void {
    const subcommand = args.next() orelse {
        printMarketplaceHelp();
        return error.MissingPluginMarketplaceSubcommand;
    };
    if (isHelpFlag(subcommand)) {
        printMarketplaceHelp();
        return;
    }
    if (std.mem.eql(u8, subcommand, "add")) {
        try runMarketplaceAdd(args);
        return;
    }
    if (std.mem.eql(u8, subcommand, "upgrade")) {
        try runMarketplaceUpgrade(args);
        return;
    }
    if (std.mem.eql(u8, subcommand, "remove")) {
        try runMarketplaceRemove(args);
        return;
    }
    return error.UnknownPluginMarketplaceSubcommand;
}

fn runMarketplaceAdd(args: *std.process.Args.Iterator) !void {
    var has_source = false;

    while (args.next()) |arg| {
        if (isHelpFlag(arg)) {
            printMarketplaceAddHelp();
            return;
        }
        if (std.mem.eql(u8, arg, "--ref")) {
            const value = args.next() orelse return error.MissingPluginMarketplaceRef;
            if (value.len == 0) return error.MissingPluginMarketplaceRef;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ref=")) {
            if (arg["--ref=".len..].len == 0) return error.MissingPluginMarketplaceRef;
            continue;
        }
        if (std.mem.eql(u8, arg, "--sparse")) {
            const value = args.next() orelse return error.MissingPluginMarketplaceSparsePath;
            if (value.len == 0) return error.MissingPluginMarketplaceSparsePath;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sparse=")) {
            if (arg["--sparse=".len..].len == 0) return error.MissingPluginMarketplaceSparsePath;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownPluginMarketplaceAddOption;
        if (has_source) return error.UnexpectedPluginMarketplaceArgument;
        has_source = true;
    }

    if (!has_source) {
        printMarketplaceAddHelp();
        return error.MissingPluginMarketplaceSource;
    }
    return notImplemented("plugin marketplace add");
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

fn runMarketplaceRemove(args: *std.process.Args.Iterator) !void {
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
    return notImplemented("plugin marketplace remove");
}

fn notImplemented(command: []const u8) !void {
    std.debug.print("codex-zig {s} is parsed but not implemented yet\n", .{command});
    return error.PluginCommandNotImplemented;
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
