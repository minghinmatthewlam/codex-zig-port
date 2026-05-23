const std = @import("std");

const config = @import("config.zig");
const env = @import("env.zig");
const marketplace_config = @import("marketplace_config.zig");
const plugin_config = @import("plugin_config.zig");
const plugin_list = @import("plugin_list.zig");

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const subcommand = args.next() orelse {
        printHelp();
        return error.MissingPluginSubcommand;
    };
    if (isHelpFlag(subcommand)) {
        printHelp();
        return;
    }
    if (std.mem.eql(u8, subcommand, "add")) {
        try runPluginAdd(allocator, args);
        return;
    }
    if (std.mem.eql(u8, subcommand, "list")) {
        try runPluginList(allocator, args);
        return;
    }
    if (std.mem.eql(u8, subcommand, "help")) {
        try runPluginHelp(args);
        return;
    }
    if (std.mem.eql(u8, subcommand, "marketplace")) {
        try runMarketplace(allocator, args);
        return;
    }
    if (std.mem.eql(u8, subcommand, "remove")) {
        try runPluginRemove(allocator, args);
        return;
    }
    return error.UnknownPluginSubcommand;
}

pub fn printHelp() void {
    std.debug.print(
        \\Manage Codex plugins
        \\
        \\Usage:
        \\  codex-zig plugin <COMMAND>
        \\
        \\Commands:
        \\  add          Install a plugin from a configured or personal marketplace snapshot
        \\  list         List plugins available from configured or personal marketplace snapshots
        \\  marketplace  Add, list, upgrade, or remove configured plugin marketplaces
        \\  remove       Remove an installed plugin from local config and cache
        \\  help         Print this message or the help of the given subcommand(s)
        \\
    , .{});
}

const PluginCommandContext = struct {
    codex_home: []const u8,
    config_path: []const u8,
    config_bytes: ?[]const u8,

    fn deinit(self: *PluginCommandContext, allocator: std.mem.Allocator) void {
        if (self.config_bytes) |bytes| allocator.free(bytes);
        allocator.free(self.config_path);
        allocator.free(self.codex_home);
    }
};

const PluginSelection = struct {
    plugin_name: []const u8,
    marketplace_name: []const u8,
    plugin_id: []const u8,

    fn deinit(self: *PluginSelection, allocator: std.mem.Allocator) void {
        allocator.free(self.plugin_name);
        allocator.free(self.marketplace_name);
        allocator.free(self.plugin_id);
    }
};

const SelectorArgs = struct {
    plugin: ?[]const u8 = null,
    marketplace_name: ?[]const u8 = null,
    help: bool = false,
};

fn runPluginHelp(args: *std.process.Args.Iterator) !void {
    const target = args.next() orelse {
        printHelp();
        return;
    };
    if (std.mem.eql(u8, target, "add")) {
        if (args.next() != null) return error.UnexpectedPluginArgument;
        printPluginAddHelp();
    } else if (std.mem.eql(u8, target, "list")) {
        if (args.next() != null) return error.UnexpectedPluginArgument;
        printPluginListHelp();
    } else if (std.mem.eql(u8, target, "marketplace")) {
        try runMarketplaceHelp(args);
    } else if (std.mem.eql(u8, target, "remove")) {
        if (args.next() != null) return error.UnexpectedPluginArgument;
        printPluginRemoveHelp();
    } else {
        return error.UnknownPluginSubcommand;
    }
}

fn runPluginAdd(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const parsed = try parseSelectorArgs(args, .add);
    if (parsed.help) {
        printPluginAddHelp();
        return;
    }
    const plugin = parsed.plugin orelse {
        printPluginAddHelp();
        return error.MissingPluginName;
    };
    var selection = parsePluginSelection(allocator, plugin, parsed.marketplace_name) catch |err| {
        try printPluginSelectionError(allocator, plugin, parsed.marketplace_name, err);
        return err;
    };
    defer selection.deinit(allocator);
    try addPluginAndPrint(allocator, selection);
}

fn runPluginList(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var marketplace_name: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (isHelpFlag(arg)) {
            printPluginListHelp();
            return;
        }
        if (std.mem.eql(u8, arg, "--marketplace") or std.mem.eql(u8, arg, "-m")) {
            const value = args.next() orelse return error.MissingPluginMarketplaceName;
            if (value.len == 0) return error.MissingPluginMarketplaceName;
            marketplace_name = value;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--marketplace=")) {
            const value = arg["--marketplace=".len..];
            if (value.len == 0) return error.MissingPluginMarketplaceName;
            marketplace_name = value;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-m") and arg.len > "-m".len) {
            marketplace_name = arg["-m".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownPluginListOption;
        return error.UnexpectedPluginArgument;
    }

    try listPluginsAndPrint(allocator, marketplace_name);
}

fn runPluginRemove(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const parsed = try parseSelectorArgs(args, .remove);
    if (parsed.help) {
        printPluginRemoveHelp();
        return;
    }
    const plugin = parsed.plugin orelse {
        printPluginRemoveHelp();
        return error.MissingPluginName;
    };
    var selection = parsePluginSelection(allocator, plugin, parsed.marketplace_name) catch |err| {
        try printPluginSelectionError(allocator, plugin, parsed.marketplace_name, err);
        return err;
    };
    defer selection.deinit(allocator);
    try removePluginAndPrint(allocator, selection);
}

const SelectorCommand = enum { add, remove };

fn parseSelectorArgs(args: *std.process.Args.Iterator, command: SelectorCommand) !SelectorArgs {
    var parsed = SelectorArgs{};
    while (args.next()) |arg| {
        if (isHelpFlag(arg)) {
            parsed.help = true;
            return parsed;
        }
        if (std.mem.eql(u8, arg, "--marketplace") or std.mem.eql(u8, arg, "-m")) {
            const value = args.next() orelse return error.MissingPluginMarketplaceName;
            if (value.len == 0) return error.MissingPluginMarketplaceName;
            parsed.marketplace_name = value;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--marketplace=")) {
            const value = arg["--marketplace=".len..];
            if (value.len == 0) return error.MissingPluginMarketplaceName;
            parsed.marketplace_name = value;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-m") and arg.len > "-m".len) {
            parsed.marketplace_name = arg["-m".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            return switch (command) {
                .add => error.UnknownPluginAddOption,
                .remove => error.UnknownPluginRemoveOption,
            };
        }
        if (parsed.plugin != null) return error.UnexpectedPluginArgument;
        parsed.plugin = arg;
    }
    return parsed;
}

fn parsePluginSelection(allocator: std.mem.Allocator, plugin: []const u8, marketplace_name: ?[]const u8) !PluginSelection {
    if (plugin_config.isValidPluginId(plugin)) {
        const parts = plugin_config.splitPluginId(plugin).?;
        if (marketplace_name) |requested| {
            if (!std.mem.eql(u8, parts.marketplace, requested)) return error.PluginMarketplaceMismatch;
        }
        return duplicatePluginSelection(allocator, parts.name, parts.marketplace);
    }

    if (marketplace_name) |marketplace| {
        if (!plugin_config.isValidPluginSegment(plugin) or !plugin_config.isValidPluginSegment(marketplace)) {
            return error.InvalidPluginId;
        }
        return duplicatePluginSelection(allocator, plugin, marketplace);
    }

    return error.PluginRequiresMarketplace;
}

fn duplicatePluginSelection(allocator: std.mem.Allocator, plugin_name: []const u8, marketplace_name: []const u8) !PluginSelection {
    const owned_plugin_name = try allocator.dupe(u8, plugin_name);
    errdefer allocator.free(owned_plugin_name);
    const owned_marketplace_name = try allocator.dupe(u8, marketplace_name);
    errdefer allocator.free(owned_marketplace_name);
    const plugin_id = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ plugin_name, marketplace_name });
    return .{
        .plugin_name = owned_plugin_name,
        .marketplace_name = owned_marketplace_name,
        .plugin_id = plugin_id,
    };
}

fn printPluginSelectionError(allocator: std.mem.Allocator, plugin: []const u8, marketplace_name: ?[]const u8, err: anyerror) !void {
    switch (err) {
        error.PluginRequiresMarketplace => std.debug.print("plugin requires --marketplace unless passed as <plugin>@<marketplace>\n", .{}),
        error.PluginMarketplaceMismatch => {
            const parts = plugin_config.splitPluginId(plugin).?;
            const requested = marketplace_name orelse "";
            const message = try std.fmt.allocPrint(
                allocator,
                "plugin id `{s}` belongs to marketplace `{s}`, but --marketplace specified `{s}`\n",
                .{ plugin, parts.marketplace, requested },
            );
            defer allocator.free(message);
            std.debug.print("{s}", .{message});
        },
        error.InvalidPluginId => std.debug.print("invalid plugin id\n", .{}),
        else => {},
    }
}

fn loadPluginCommandContext(allocator: std.mem.Allocator) !PluginCommandContext {
    const codex_home = try resolvePluginCodexHome(allocator);
    errdefer allocator.free(codex_home);
    const config_path = try config.configTomlPath(allocator, codex_home);
    errdefer allocator.free(config_path);
    const config_bytes = try config.readConfigTomlFile(allocator, config_path);
    return .{
        .codex_home = codex_home,
        .config_path = config_path,
        .config_bytes = config_bytes,
    };
}

fn resolvePluginCodexHome(allocator: std.mem.Allocator) ![]const u8 {
    const raw = try config.resolveCodexHome(allocator);
    defer allocator.free(raw);
    if (std.fs.path.isAbsolute(raw)) return allocator.dupe(u8, raw);

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, raw });
}

fn addPluginAndPrint(allocator: std.mem.Allocator, selection: PluginSelection) !void {
    var context = try loadPluginCommandContext(allocator);
    defer context.deinit(allocator);
    const config_bytes = context.config_bytes orelse "";

    const marketplace_path = findMarketplacePathForPlugin(allocator, context.codex_home, config_bytes, selection) catch |err| {
        try printFindMarketplaceError(allocator, selection, err);
        return err;
    };
    defer allocator.free(marketplace_path);

    const install = plugin_list.installLocalPlugin(allocator, context.codex_home, config_bytes, marketplace_path, selection.plugin_name) catch |err| {
        try printPluginInstallError(allocator, selection, err);
        return err;
    };
    defer install.deinit(allocator);
    try config.writeConfigTomlFile(context.config_path, install.updated_config);

    std.debug.print("Added plugin `{s}` from marketplace `{s}`.\n", .{ selection.plugin_name, selection.marketplace_name });
    std.debug.print("Installed plugin root: {s}\n", .{install.installed_path});
}

fn listPluginsAndPrint(allocator: std.mem.Allocator, marketplace_filter: ?[]const u8) !void {
    var context = try loadPluginCommandContext(allocator);
    defer context.deinit(allocator);

    const home_root = try resolveHomeMarketplaceRoot(allocator);
    defer if (home_root) |root| allocator.free(root);
    const response = try plugin_list.renderCliResponse(allocator, context.codex_home, context.config_bytes orelse "", home_root);
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    if (marketplace_filter) |filter| {
        try failOnMarketplaceLoadErrorsForMarketplace(allocator, parsed.value, filter);
    } else {
        try failOnMarketplaceLoadErrors(allocator, parsed.value);
    }

    const marketplaces = parsed.value.object.get("marketplaces") orelse return error.InvalidPluginListResponse;
    if (marketplaces != .array) return error.InvalidPluginListResponse;

    var matched_marketplaces: usize = 0;
    for (marketplaces.array.items) |marketplace| {
        if (marketplace != .object) return error.InvalidPluginListResponse;
        const marketplace_name = stringField(marketplace.object, "name") orelse return error.InvalidPluginListResponse;
        if (marketplace_filter) |filter| {
            if (!std.mem.eql(u8, marketplace_name, filter)) continue;
        }
        if (matched_marketplaces > 0) std.debug.print("\n", .{});
        matched_marketplaces += 1;
        try printMarketplacePluginTable(allocator, context.codex_home, marketplace);
    }

    if (matched_marketplaces == 0) {
        if (marketplace_filter) |name| {
            std.debug.print("No plugins found in marketplace `{s}`.\n", .{name});
        } else {
            std.debug.print("No marketplace plugins found.\n", .{});
        }
    }
}

const MarketplaceListRow = struct {
    marketplace_name: []const u8,
    root: []const u8,

    fn deinit(self: *MarketplaceListRow, allocator: std.mem.Allocator) void {
        allocator.free(self.marketplace_name);
        allocator.free(self.root);
    }
};

const MarketplaceListIssue = struct {
    marketplace_name: []const u8,
    path: []const u8,
    message: []const u8,

    fn deinit(self: *MarketplaceListIssue, allocator: std.mem.Allocator) void {
        allocator.free(self.marketplace_name);
        allocator.free(self.path);
        allocator.free(self.message);
    }
};

fn listMarketplacesAndPrint(allocator: std.mem.Allocator) !void {
    var context = try loadPluginCommandContext(allocator);
    defer context.deinit(allocator);

    var rows = std.ArrayList(MarketplaceListRow).empty;
    defer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    var issues = std.ArrayList(MarketplaceListIssue).empty;
    defer {
        for (issues.items) |*issue| issue.deinit(allocator);
        issues.deinit(allocator);
    }

    const config_bytes = context.config_bytes orelse "";
    if (plugin_config.pluginsFeatureEnabled(config_bytes)) {
        if (try resolveHomeMarketplaceRoot(allocator)) |home| {
            defer allocator.free(home);
            try appendMarketplaceListRoot(allocator, &rows, &issues, null, home, false);
        }

        var configured = try marketplace_config.configuredMarketplaceRootsStrict(allocator, context.codex_home, config_bytes);
        defer configured.deinit(allocator);
        for (configured.issues) |issue| {
            try appendMarketplaceListIssue(allocator, &issues, issue.marketplace_name, issue.marketplace_path, issue.message);
        }
        for (configured.roots) |root| {
            try appendMarketplaceListRoot(allocator, &rows, &issues, root.marketplace_name, root.root, true);
        }
    }

    try failOnMarketplaceListIssues(issues.items);
    if (rows.items.len == 0) {
        std.debug.print("No plugin marketplaces in scope.\n", .{});
        return;
    }

    var marketplace_width: usize = "MARKETPLACE".len;
    for (rows.items) |row| {
        marketplace_width = @max(marketplace_width, row.marketplace_name.len);
    }

    printPadded("MARKETPLACE", marketplace_width);
    std.debug.print("  ROOT\n", .{});
    for (rows.items) |row| {
        printPadded(row.marketplace_name, marketplace_width);
        std.debug.print("  {s}\n", .{row.root});
    }
}

fn appendMarketplaceListRoot(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(MarketplaceListRow),
    issues: *std.ArrayList(MarketplaceListIssue),
    configured_marketplace_name: ?[]const u8,
    root: []const u8,
    fail_missing_manifest: bool,
) !void {
    for (plugin_list.MARKETPLACE_MANIFEST_RELATIVE_PATHS) |relative_path| {
        const marketplace_path = try std.fs.path.join(allocator, &.{ root, relative_path });
        defer allocator.free(marketplace_path);
        const bytes = readFileOptional(allocator, marketplace_path, 1024 * 1024) catch |err| {
            const name = configured_marketplace_name orelse marketplace_path;
            const message = try std.fmt.allocPrint(allocator, "failed to read marketplace file: {s}", .{@errorName(err)});
            defer allocator.free(message);
            try appendMarketplaceListIssue(allocator, issues, name, marketplace_path, message);
            return;
        } orelse continue;
        defer allocator.free(bytes);
        try appendMarketplaceListRowFromBytes(allocator, rows, issues, configured_marketplace_name, marketplace_path, bytes);
        return;
    }

    if (!fail_missing_manifest) return;
    const name = configured_marketplace_name orelse root;
    if (configured_marketplace_name) |configured_name| {
        if (plugin_list.isImplicitSystemMarketplaceRoot(configured_name, root)) return;
    }
    try appendMarketplaceListIssue(allocator, issues, name, root, "marketplace root does not contain a supported manifest");
}

fn appendMarketplaceListRowFromBytes(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(MarketplaceListRow),
    issues: *std.ArrayList(MarketplaceListIssue),
    configured_marketplace_name: ?[]const u8,
    marketplace_path: []const u8,
    bytes: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        const name = configured_marketplace_name orelse marketplace_path;
        try appendMarketplaceListIssue(allocator, issues, name, marketplace_path, "invalid marketplace file");
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        const name = configured_marketplace_name orelse marketplace_path;
        try appendMarketplaceListIssue(allocator, issues, name, marketplace_path, "invalid marketplace file: root must be an object");
        return;
    }
    const object = parsed.value.object;
    const marketplace_name = stringField(object, "name") orelse {
        const name = configured_marketplace_name orelse marketplace_path;
        try appendMarketplaceListIssue(allocator, issues, name, marketplace_path, "invalid marketplace file: name must be a string");
        return;
    };
    const plugins_value = object.get("plugins") orelse {
        const name = configured_marketplace_name orelse marketplace_path;
        try appendMarketplaceListIssue(allocator, issues, name, marketplace_path, "invalid marketplace file: plugins must be an array");
        return;
    };
    if (plugins_value != .array) {
        const name = configured_marketplace_name orelse marketplace_path;
        try appendMarketplaceListIssue(allocator, issues, name, marketplace_path, "invalid marketplace file: plugins must be an array");
        return;
    }

    const root = try plugin_list.marketplaceRootDir(allocator, marketplace_path);
    errdefer allocator.free(root);
    if (marketplaceListContainsRoot(rows.items, root)) {
        allocator.free(root);
        return;
    }
    const name = try allocator.dupe(u8, marketplace_name);
    errdefer allocator.free(name);
    try rows.append(allocator, .{ .marketplace_name = name, .root = root });
}

fn appendMarketplaceListIssue(
    allocator: std.mem.Allocator,
    issues: *std.ArrayList(MarketplaceListIssue),
    marketplace_name: []const u8,
    path: []const u8,
    message: []const u8,
) !void {
    const owned_name = try allocator.dupe(u8, marketplace_name);
    errdefer allocator.free(owned_name);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const owned_message = try allocator.dupe(u8, message);
    errdefer allocator.free(owned_message);
    try issues.append(allocator, .{
        .marketplace_name = owned_name,
        .path = owned_path,
        .message = owned_message,
    });
}

fn failOnMarketplaceListIssues(issues: []MarketplaceListIssue) !void {
    if (issues.len == 0) return;
    std.debug.print("failed to load marketplace(s):\n", .{});
    for (issues) |issue| {
        std.debug.print("- `{s}` at {s}: {s}\n", .{ issue.marketplace_name, issue.path, issue.message });
    }
    return error.PluginMarketplaceLoadFailed;
}

fn marketplaceListContainsRoot(rows: []const MarketplaceListRow, root: []const u8) bool {
    for (rows) |row| {
        if (std.mem.eql(u8, row.root, root)) return true;
    }
    return false;
}

fn readFileOptional(allocator: std.mem.Allocator, path: []const u8, limit: usize) !?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
}

fn resolveHomeMarketplaceRoot(allocator: std.mem.Allocator) !?[]const u8 {
    const home = try env.getOwned(allocator, "HOME");
    defer if (home) |value| allocator.free(value);
    const userprofile = try env.getOwned(allocator, "USERPROFILE");
    defer if (userprofile) |value| allocator.free(value);

    return resolvePreferredHomePath(allocator, home, userprofile, resolveOsHomePath());
}

fn resolvePreferredHomePath(allocator: std.mem.Allocator, home: ?[]const u8, userprofile: ?[]const u8, os_home: ?[]const u8) !?[]const u8 {
    const candidates = [_]?[]const u8{ home, userprofile, os_home };
    for (candidates) |candidate| {
        const value = candidate orelse continue;
        if (value.len == 0 or !std.fs.path.isAbsolute(value)) continue;
        return try allocator.dupe(u8, value);
    }
    return null;
}

fn resolveOsHomePath() ?[]const u8 {
    if (!@hasDecl(std.c, "getpwuid") or !@hasDecl(std.c, "getuid")) return null;
    const passwd = std.c.getpwuid(std.c.getuid()) orelse return null;
    const dir = passwd.dir orelse return null;
    return std.mem.span(dir);
}

test "home marketplace root prefers env paths before OS fallback" {
    const allocator = std.testing.allocator;

    const home = try resolvePreferredHomePath(allocator, "/tmp/home", "/tmp/userprofile", "/tmp/os-home");
    try std.testing.expect(home != null);
    defer allocator.free(home.?);
    try std.testing.expectEqualStrings("/tmp/home", home.?);

    const userprofile = try resolvePreferredHomePath(allocator, "relative-home", "/tmp/userprofile", "/tmp/os-home");
    try std.testing.expect(userprofile != null);
    defer allocator.free(userprofile.?);
    try std.testing.expectEqualStrings("/tmp/userprofile", userprofile.?);

    const os_home = try resolvePreferredHomePath(allocator, null, "", "/tmp/os-home");
    try std.testing.expect(os_home != null);
    defer allocator.free(os_home.?);
    try std.testing.expectEqualStrings("/tmp/os-home", os_home.?);

    const absent = try resolvePreferredHomePath(allocator, null, "relative", null);
    try std.testing.expect(absent == null);
}

fn removePluginAndPrint(allocator: std.mem.Allocator, selection: PluginSelection) !void {
    var context = try loadPluginCommandContext(allocator);
    defer context.deinit(allocator);

    const plugin_base_root = (try plugin_config.localPluginBaseRoot(allocator, context.codex_home, selection.plugin_id)) orelse return error.InvalidPluginId;
    defer allocator.free(plugin_base_root);
    try deletePathIfPresent(allocator, plugin_base_root);

    const updated_config = try plugin_config.removePluginConfig(allocator, context.config_bytes orelse "", selection.plugin_id);
    defer allocator.free(updated_config);
    if (!std.mem.eql(u8, updated_config, context.config_bytes orelse "")) {
        try config.writeConfigTomlFile(context.config_path, updated_config);
    }

    std.debug.print("Removed plugin `{s}` from marketplace `{s}`.\n", .{ selection.plugin_name, selection.marketplace_name });
}

fn findMarketplacePathForPlugin(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    selection: PluginSelection,
) ![]const u8 {
    const home_root = try resolveHomeMarketplaceRoot(allocator);
    defer if (home_root) |root| allocator.free(root);
    const response = try plugin_list.renderCliResponse(allocator, codex_home, config_bytes, home_root);
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    try failOnMarketplaceLoadErrorsForMarketplace(allocator, parsed.value, selection.marketplace_name);
    const marketplaces = parsed.value.object.get("marketplaces") orelse return error.InvalidPluginListResponse;
    if (marketplaces != .array) return error.InvalidPluginListResponse;

    var found_path: ?[]const u8 = null;
    errdefer if (found_path) |path| allocator.free(path);
    for (marketplaces.array.items) |marketplace| {
        if (marketplace != .object) return error.InvalidPluginListResponse;
        const marketplace_name = stringField(marketplace.object, "name") orelse return error.InvalidPluginListResponse;
        if (!std.mem.eql(u8, marketplace_name, selection.marketplace_name)) continue;
        if (!marketplaceContainsPlugin(marketplace.object, selection.plugin_name)) continue;
        if (found_path != null) return error.MultipleMatchingPluginMarketplaces;
        const marketplace_path = stringField(marketplace.object, "path") orelse return error.InvalidPluginListResponse;
        found_path = try allocator.dupe(u8, marketplace_path);
    }
    return found_path orelse error.PluginNotFound;
}

fn marketplaceContainsPlugin(marketplace: std.json.ObjectMap, plugin_name: []const u8) bool {
    const plugins = marketplace.get("plugins") orelse return false;
    if (plugins != .array) return false;
    for (plugins.array.items) |plugin| {
        if (plugin != .object) continue;
        const name = stringField(plugin.object, "name") orelse continue;
        if (std.mem.eql(u8, name, plugin_name)) return true;
    }
    return false;
}

fn failOnMarketplaceLoadErrors(allocator: std.mem.Allocator, value: std.json.Value) !void {
    return failOnMarketplaceLoadErrorsFiltered(allocator, value, null);
}

fn failOnMarketplaceLoadErrorsForMarketplace(allocator: std.mem.Allocator, value: std.json.Value, marketplace_name: []const u8) !void {
    return failOnMarketplaceLoadErrorsFiltered(allocator, value, marketplace_name);
}

fn failOnMarketplaceLoadErrorsFiltered(allocator: std.mem.Allocator, value: std.json.Value, marketplace_filter: ?[]const u8) !void {
    if (value != .object) return error.InvalidPluginListResponse;
    const errors = value.object.get("marketplaceLoadErrors") orelse return;
    if (errors != .array) return error.InvalidPluginListResponse;
    if (errors.array.items.len == 0) return;

    var printed_header = false;
    for (errors.array.items) |issue| {
        if (issue != .object) return error.InvalidPluginListResponse;
        const marketplace_name = optionalStringFieldFromJson(issue.object, "marketplaceName");
        if (marketplace_filter) |filter| {
            if (marketplace_name == null or !std.mem.eql(u8, marketplace_name.?, filter)) continue;
        }
        if (!printed_header) {
            std.debug.print("failed to load configured marketplace snapshot(s):\n", .{});
            printed_header = true;
        }
        const path = stringField(issue.object, "marketplacePath") orelse "<unknown>";
        const message = stringField(issue.object, "message") orelse "unknown error";
        const line = if (marketplace_name) |name|
            try std.fmt.allocPrint(allocator, "- `{s}` at {s}: {s}\n", .{ name, path, message })
        else
            try std.fmt.allocPrint(allocator, "- `{s}`: {s}\n", .{ path, message });
        defer allocator.free(line);
        std.debug.print("{s}", .{line});
    }
    if (!printed_header) return;
    return error.PluginMarketplaceLoadFailed;
}

const PluginRow = struct {
    plugin_id: []const u8,
    status: []const u8,
    version: []const u8,
    path: []const u8,

    fn deinit(self: *PluginRow, allocator: std.mem.Allocator) void {
        allocator.free(self.version);
        allocator.free(self.path);
    }
};

fn printMarketplacePluginTable(allocator: std.mem.Allocator, codex_home: []const u8, marketplace: std.json.Value) !void {
    const marketplace_name = stringField(marketplace.object, "name") orelse return error.InvalidPluginListResponse;
    const marketplace_path = stringField(marketplace.object, "path") orelse return error.InvalidPluginListResponse;
    const plugins = marketplace.object.get("plugins") orelse return error.InvalidPluginListResponse;
    if (plugins != .array) return error.InvalidPluginListResponse;

    var rows = std.ArrayList(PluginRow).empty;
    defer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    var plugin_width: usize = "PLUGIN".len;
    var status_width: usize = "STATUS".len;
    var version_width: usize = "VERSION".len;
    var path_width: usize = "PATH".len;

    for (plugins.array.items) |plugin| {
        if (plugin != .object) return error.InvalidPluginListResponse;
        const plugin_id = stringField(plugin.object, "id") orelse return error.InvalidPluginListResponse;
        const installed = boolField(plugin.object, "installed") orelse return error.InvalidPluginListResponse;
        const enabled = boolField(plugin.object, "enabled") orelse return error.InvalidPluginListResponse;
        const status = if (installed and enabled)
            "installed, enabled"
        else if (installed)
            "installed, disabled"
        else
            "not installed";
        const version = try installedPluginVersion(allocator, codex_home, plugin_id, installed);
        errdefer allocator.free(version);
        const source = plugin.object.get("source") orelse return error.InvalidPluginListResponse;
        const path = try pluginSourceDisplay(allocator, source);
        errdefer allocator.free(path);

        plugin_width = @max(plugin_width, plugin_id.len);
        status_width = @max(status_width, status.len);
        version_width = @max(version_width, version.len);
        path_width = @max(path_width, path.len);
        try rows.append(allocator, .{
            .plugin_id = plugin_id,
            .status = status,
            .version = version,
            .path = path,
        });
    }

    std.debug.print("Marketplace `{s}`\n", .{marketplace_name});
    std.debug.print("{s}\n\n", .{marketplace_path});
    printPadded("PLUGIN", plugin_width);
    std.debug.print("  ", .{});
    printPadded("STATUS", status_width);
    std.debug.print("  ", .{});
    printPadded("VERSION", version_width);
    std.debug.print("  ", .{});
    printPadded("PATH", path_width);
    std.debug.print("\n", .{});
    for (rows.items) |row| {
        printPadded(row.plugin_id, plugin_width);
        std.debug.print("  ", .{});
        printPadded(row.status, status_width);
        std.debug.print("  ", .{});
        printPadded(row.version, version_width);
        std.debug.print("  ", .{});
        printPadded(row.path, path_width);
        std.debug.print("\n", .{});
    }
}

fn printPadded(value: []const u8, width: usize) void {
    std.debug.print("{s}", .{value});
    var index = value.len;
    while (index < width) : (index += 1) {
        std.debug.print(" ", .{});
    }
}

fn installedPluginVersion(allocator: std.mem.Allocator, codex_home: []const u8, plugin_id: []const u8, installed: bool) ![]const u8 {
    if (!installed) return allocator.dupe(u8, "");
    const root = (try plugin_config.localPluginRoot(allocator, codex_home, plugin_id)) orelse return allocator.dupe(u8, "");
    defer allocator.free(root);
    return allocator.dupe(u8, std.fs.path.basename(root));
}

fn pluginSourceDisplay(allocator: std.mem.Allocator, source: std.json.Value) ![]const u8 {
    if (source != .object) return error.InvalidPluginListResponse;
    const source_type = stringField(source.object, "type") orelse return error.InvalidPluginListResponse;
    if (std.mem.eql(u8, source_type, "local")) {
        const path = stringField(source.object, "path") orelse return error.InvalidPluginListResponse;
        return allocator.dupe(u8, path);
    }
    if (std.mem.eql(u8, source_type, "git")) {
        const url = stringField(source.object, "url") orelse return error.InvalidPluginListResponse;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, url);
        if (optionalStringFieldFromJson(source.object, "path")) |path| {
            try out.appendSlice(allocator, ", path `");
            try out.appendSlice(allocator, path);
            try out.appendSlice(allocator, "`");
        }
        if (optionalStringFieldFromJson(source.object, "refName")) |ref_name| {
            try out.appendSlice(allocator, ", ref `");
            try out.appendSlice(allocator, ref_name);
            try out.appendSlice(allocator, "`");
        }
        if (optionalStringFieldFromJson(source.object, "sha")) |sha| {
            try out.appendSlice(allocator, ", sha `");
            try out.appendSlice(allocator, sha);
            try out.appendSlice(allocator, "`");
        }
        return out.toOwnedSlice(allocator);
    }
    if (std.mem.eql(u8, source_type, "remote")) {
        return allocator.dupe(u8, "remote");
    }
    return error.InvalidPluginListResponse;
}

fn deletePathIfPresent(allocator: std.mem.Allocator, path: []const u8) !void {
    const metadata = (try statPathNoFollow(allocator, path)) orelse return;
    const io = std.Io.Threaded.global_single_threaded.io();
    const mode: u32 = @intCast(metadata.mode);
    if (std.c.S.ISDIR(mode)) {
        try std.Io.Dir.cwd().deleteTree(io, path);
    } else {
        try std.Io.Dir.deleteFileAbsolute(io, path);
    }
}

fn statPathNoFollow(allocator: std.mem.Allocator, path: []const u8) !?std.c.Stat {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var stat = std.mem.zeroes(std.c.Stat);
    while (true) {
        switch (std.c.errno(std.c.fstatat(std.c.AT.FDCWD, path_z.ptr, &stat, std.c.AT.SYMLINK_NOFOLLOW))) {
            .SUCCESS => break,
            .INTR => continue,
            .NOENT => return null,
            .NOTDIR => return error.NotDir,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
    return stat;
}

fn printFindMarketplaceError(allocator: std.mem.Allocator, selection: PluginSelection, err: anyerror) !void {
    switch (err) {
        error.PluginNotFound => {
            const message = try std.fmt.allocPrint(
                allocator,
                "plugin `{s}` was not found in marketplace `{s}`\n",
                .{ selection.plugin_name, selection.marketplace_name },
            );
            defer allocator.free(message);
            std.debug.print("{s}", .{message});
        },
        error.MultipleMatchingPluginMarketplaces => {
            const message = try std.fmt.allocPrint(
                allocator,
                "plugin `{s}` in marketplace `{s}` matched multiple marketplace roots\n",
                .{ selection.plugin_name, selection.marketplace_name },
            );
            defer allocator.free(message);
            std.debug.print("{s}", .{message});
        },
        else => {},
    }
}

fn printPluginInstallError(allocator: std.mem.Allocator, selection: PluginSelection, err: anyerror) !void {
    switch (err) {
        plugin_list.InstallError.InvalidMarketplaceFile => std.debug.print("invalid marketplace file\n", .{}),
        plugin_list.InstallError.PluginNotFound => try printFindMarketplaceError(allocator, selection, error.PluginNotFound),
        plugin_list.InstallError.MissingPluginManifest => std.debug.print("missing or invalid plugin.json\n", .{}),
        plugin_list.InstallError.PluginsDisabled => std.debug.print("plugins are disabled\n", .{}),
        plugin_list.InstallError.UnsupportedInstallSource => std.debug.print("plugin install source is parsed but not implemented yet\n", .{}),
        plugin_list.InstallError.PluginNotAvailable => std.debug.print("plugin is not available for install\n", .{}),
        plugin_list.InstallError.InvalidPluginId => std.debug.print("invalid plugin id\n", .{}),
        plugin_list.InstallError.PluginNameMismatch => std.debug.print("plugin.json name does not match marketplace plugin name\n", .{}),
        plugin_list.InstallError.InvalidPluginVersion => std.debug.print("invalid plugin version\n", .{}),
        else => {
            const message = try std.fmt.allocPrint(allocator, "failed to add plugin: {s}\n", .{@errorName(err)});
            defer allocator.free(message);
            std.debug.print("{s}", .{message});
        },
    }
}

fn stringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn boolField(object: std.json.ObjectMap, field: []const u8) ?bool {
    const value = object.get(field) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

fn optionalStringFieldFromJson(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value == .null) return null;
    if (value != .string) return null;
    return value.string;
}

fn printPluginAddHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig plugin add [--marketplace MARKETPLACE] PLUGIN[@MARKETPLACE]
        \\
        \\Options:
        \\  -m, --marketplace MARKETPLACE
        \\                      Marketplace name to use when PLUGIN does not include @MARKETPLACE
        \\
        \\Examples:
        \\  codex-zig plugin add sample@debug
        \\  codex-zig plugin add sample --marketplace debug
        \\
    , .{});
}

fn printPluginListHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig plugin list [--marketplace MARKETPLACE]
        \\
        \\Options:
        \\  -m, --marketplace MARKETPLACE
        \\                      Only list plugins from this configured marketplace name
        \\
        \\Examples:
        \\  codex-zig plugin list
        \\  codex-zig plugin list --marketplace debug
        \\
    , .{});
}

fn printPluginRemoveHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig plugin remove [--marketplace MARKETPLACE] PLUGIN[@MARKETPLACE]
        \\
        \\Options:
        \\  -m, --marketplace MARKETPLACE
        \\                      Marketplace name to use when PLUGIN does not include @MARKETPLACE
        \\
        \\Examples:
        \\  codex-zig plugin remove sample@debug
        \\  codex-zig plugin remove sample --marketplace debug
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
    if (std.mem.eql(u8, subcommand, "list")) {
        try runMarketplaceList(allocator, args);
        return;
    }
    if (std.mem.eql(u8, subcommand, "upgrade")) {
        try runMarketplaceUpgrade(allocator, args);
        return;
    }
    if (std.mem.eql(u8, subcommand, "remove")) {
        try runMarketplaceRemove(allocator, args);
        return;
    }
    if (std.mem.eql(u8, subcommand, "help")) {
        try runMarketplaceHelp(args);
        return;
    }
    return error.UnknownPluginMarketplaceSubcommand;
}

fn runMarketplaceHelp(args: *std.process.Args.Iterator) !void {
    const target = args.next() orelse {
        printMarketplaceHelp();
        return;
    };
    if (args.next() != null) return error.UnexpectedPluginMarketplaceArgument;
    if (std.mem.eql(u8, target, "add")) {
        printMarketplaceAddHelp();
    } else if (std.mem.eql(u8, target, "list")) {
        printMarketplaceListHelp();
    } else if (std.mem.eql(u8, target, "upgrade")) {
        printMarketplaceUpgradeHelp();
    } else if (std.mem.eql(u8, target, "remove")) {
        printMarketplaceRemoveHelp();
    } else {
        return error.UnknownPluginMarketplaceSubcommand;
    }
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

fn runMarketplaceList(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    while (args.next()) |arg| {
        if (isHelpFlag(arg)) {
            printMarketplaceListHelp();
            return;
        }
        return error.UnexpectedPluginMarketplaceArgument;
    }
    try listMarketplacesAndPrint(allocator);
}

fn runMarketplaceUpgrade(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var marketplace_name: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (isHelpFlag(arg)) {
            printMarketplaceUpgradeHelp();
            return;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownPluginMarketplaceUpgradeOption;
        if (marketplace_name != null) return error.UnexpectedPluginMarketplaceArgument;
        marketplace_name = arg;
    }

    return upgradeMarketplacesAndPrint(allocator, marketplace_name);
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

fn addMarketplaceAndPrint(allocator: std.mem.Allocator, source: []const u8, ref_name: ?[]const u8, sparse_paths: []const []const u8) !void {
    const codex_home = try resolvePluginCodexHome(allocator);
    defer allocator.free(codex_home);
    const config_path = try config.configTomlPath(allocator, codex_home);
    defer allocator.free(config_path);
    const config_bytes = try config.readConfigTomlFile(allocator, config_path);
    defer if (config_bytes) |bytes| allocator.free(bytes);

    const add = marketplace_config.addMarketplace(allocator, codex_home, config_bytes orelse "", source, ref_name, sparse_paths) catch |err| {
        try printAddError(allocator, err);
        return err;
    };
    defer add.deinit(allocator);
    try config.writeConfigTomlFile(config_path, add.updated_config);

    if (add.already_added) {
        std.debug.print("Marketplace `{s}` is already added from {s}.\n", .{ add.marketplace_name, add.source_display });
    } else {
        std.debug.print("Added marketplace `{s}` from {s}.\n", .{ add.marketplace_name, add.source_display });
    }
    std.debug.print("Installed marketplace root: {s}\n", .{add.installed_root});
}

fn upgradeMarketplacesAndPrint(allocator: std.mem.Allocator, marketplace_name: ?[]const u8) !void {
    const codex_home = try resolvePluginCodexHome(allocator);
    defer allocator.free(codex_home);
    const config_path = try config.configTomlPath(allocator, codex_home);
    defer allocator.free(config_path);
    const config_bytes = try config.readConfigTomlFile(allocator, config_path);
    defer if (config_bytes) |bytes| allocator.free(bytes);

    const upgraded = marketplace_config.upgradeMarketplaces(allocator, codex_home, config_bytes orelse "", marketplace_name) catch |err| {
        try printUpgradeFatalError(allocator, marketplace_name, err);
        return err;
    };
    defer upgraded.deinit(allocator);

    if (upgraded.upgraded_roots.len > 0) {
        try config.writeConfigTomlFile(config_path, upgraded.updated_config);
    }

    if (upgraded.errors.len > 0) {
        for (upgraded.errors) |failure| {
            std.debug.print("Failed to upgrade marketplace `{s}`: {s}\n", .{ failure.marketplace_name, failure.message });
        }
        std.debug.print("{d} upgrade failure(s) occurred.\n", .{upgraded.errors.len});
        return error.PluginMarketplaceUpgradeFailed;
    }

    if (upgraded.upgraded_roots.len == 0) {
        if (marketplace_name) |name| {
            std.debug.print("Marketplace `{s}` is already up to date.\n", .{name});
        } else if (upgraded.selected_marketplaces.len == 0) {
            std.debug.print("No configured Git marketplaces to upgrade.\n", .{});
        } else {
            std.debug.print("All configured Git marketplaces are already up to date.\n", .{});
        }
        return;
    }

    if (marketplace_name) |name| {
        std.debug.print("Upgraded marketplace `{s}` to the latest configured revision.\n", .{name});
    } else {
        std.debug.print("Upgraded {d} marketplace(s).\n", .{upgraded.upgraded_roots.len});
    }
    for (upgraded.upgraded_roots) |root| {
        std.debug.print("Installed marketplace root: {s}\n", .{root});
    }
}

fn removeMarketplaceAndPrint(allocator: std.mem.Allocator, marketplace_name: []const u8) !void {
    const codex_home = try resolvePluginCodexHome(allocator);
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
        error.InvalidMarketplaceSourceFormat => std.debug.print("invalid marketplace source format; expected owner/repo, a git URL, or a local marketplace path\n", .{}),
        error.MarketplaceSourceEmpty => std.debug.print("marketplace source must not be empty\n", .{}),
        error.RefUnsupportedForLocalSource => std.debug.print("--ref is only supported for git marketplace sources\n", .{}),
        error.SparseUnsupportedForLocalSource => std.debug.print("--sparse is only supported for git marketplace sources\n", .{}),
        error.InvalidLocalMarketplaceSource => std.debug.print("failed to resolve local marketplace source path\n", .{}),
        error.LocalMarketplaceSourceMustBeDirectory => std.debug.print("local marketplace source must be a directory, not a file\n", .{}),
        error.InvalidMarketplaceRoot => std.debug.print("invalid marketplace root\n", .{}),
        error.InvalidMarketplaceName => std.debug.print("invalid marketplace name\n", .{}),
        error.ReservedMarketplaceName => std.debug.print("marketplace 'openai-curated' is reserved and cannot be added from this source\n", .{}),
        error.MarketplaceAlreadyAddedDifferentSource => std.debug.print("marketplace is already added from a different source; remove it before adding this source\n", .{}),
        error.GitCommandFailed => std.debug.print("failed to clone marketplace git source\n", .{}),
        else => {
            const message = try std.fmt.allocPrint(allocator, "failed to add marketplace: {s}\n", .{@errorName(err)});
            defer allocator.free(message);
            std.debug.print("{s}", .{message});
        },
    };
}

fn printUpgradeFatalError(allocator: std.mem.Allocator, marketplace_name: ?[]const u8, err: anyerror) !void {
    return switch (err) {
        error.MarketplaceNotConfiguredAsGit => {
            const name = marketplace_name orelse "";
            const message = try std.fmt.allocPrint(allocator, "marketplace `{s}` is not configured as a Git marketplace\n", .{name});
            defer allocator.free(message);
            std.debug.print("{s}", .{message});
        },
        else => {
            const message = try std.fmt.allocPrint(allocator, "failed to upgrade marketplace: {s}\n", .{@errorName(err)});
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
        \\  list                List marketplace roots currently in scope
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

fn printMarketplaceListHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig plugin marketplace list
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
