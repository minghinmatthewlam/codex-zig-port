const std = @import("std");

const auth = @import("auth.zig");

const MAX_REMOTE_DEFAULT_PROMPT_LEN = 128;

const RemotePluginScope = enum {
    global,
    workspace,
};

const RemotePluginDetailPayload = struct {
    id: []const u8,
    name: []const u8,
    scope: []const u8,
    creator_account_user_id: ?[]const u8 = null,
    creator_name: ?[]const u8 = null,
    share_url: ?[]const u8 = null,
    share_principals: ?[]const RemotePluginSharePrincipalPayload = null,
    installation_policy: []const u8,
    authentication_policy: []const u8,
    status: ?[]const u8 = null,
    release: RemotePluginReleasePayload,
};

const RemotePluginSharePrincipalPayload = struct {
    principal_type: []const u8,
    principal_id: []const u8,
    role: ?[]const u8 = null,
    name: []const u8,
};

const RemotePluginReleasePayload = struct {
    version: ?[]const u8 = null,
    display_name: []const u8,
    description: []const u8,
    bundle_download_url: ?[]const u8 = null,
    app_ids: ?[]const []const u8 = null,
    keywords: ?[]const []const u8 = null,
    interface: RemotePluginInterfacePayload = .{},
    skills: ?[]const RemotePluginSkillPayload = null,
};

const RemotePluginInterfacePayload = struct {
    short_description: ?[]const u8 = null,
    long_description: ?[]const u8 = null,
    developer_name: ?[]const u8 = null,
    category: ?[]const u8 = null,
    capabilities: ?[]const []const u8 = null,
    website_url: ?[]const u8 = null,
    privacy_policy_url: ?[]const u8 = null,
    terms_of_service_url: ?[]const u8 = null,
    default_prompt: ?[]const u8 = null,
    brand_color: ?[]const u8 = null,
    composer_icon_url: ?[]const u8 = null,
    logo_url: ?[]const u8 = null,
    screenshot_urls: ?[]const []const u8 = null,
};

const RemotePluginSkillPayload = struct {
    name: []const u8,
    description: []const u8,
    interface: ?RemotePluginSkillInterfacePayload = null,
};

const RemotePluginSkillInterfacePayload = struct {
    display_name: ?[]const u8 = null,
    short_description: ?[]const u8 = null,
    brand_color: ?[]const u8 = null,
    default_prompt: ?[]const u8 = null,
};

const RemotePluginSkillDetailPayload = struct {
    plugin_id: []const u8,
    name: []const u8,
    skill_md_contents: ?[]const u8 = null,
};

const RemotePluginPaginationPayload = struct {
    next_page_token: ?[]const u8 = null,
};

const RemotePluginListResponsePayload = struct {
    plugins: ?[]const RemotePluginDetailPayload = null,
    pagination: RemotePluginPaginationPayload = .{},
};

const RemotePluginInstalledResponsePayload = struct {
    plugins: ?[]const RemotePluginInstalledItemPayload = null,
    pagination: RemotePluginPaginationPayload = .{},
};

const RemotePluginInstalledItemPayload = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    creator_account_user_id: ?[]const u8 = null,
    creator_name: ?[]const u8 = null,
    share_url: ?[]const u8 = null,
    share_principals: ?[]const RemotePluginSharePrincipalPayload = null,
    installation_policy: ?[]const u8 = null,
    authentication_policy: ?[]const u8 = null,
    status: ?[]const u8 = null,
    release: ?RemotePluginReleasePayload = null,
    enabled: bool,
    disabled_skill_names: ?[]const []const u8 = null,
};

pub const MarketplaceSources = struct {
    global: bool = false,
    workspace_directory: bool = false,
    shared_with_me: bool = false,

    pub fn isEmpty(self: MarketplaceSources) bool {
        return !self.global and !self.workspace_directory and !self.shared_with_me;
    }
};

const RemotePluginListSource = union(enum) {
    scoped: RemotePluginScope,
    shared_workspace,
};

const RemotePluginListPages = std.ArrayList(std.json.Parsed(RemotePluginListResponsePayload));
const RemoteInstalledPluginPages = std.ArrayList(std.json.Parsed(RemotePluginInstalledResponsePayload));

const RemoteMarketplacePluginEntry = struct {
    detail: RemotePluginDetailPayload,
    scope: RemotePluginScope,
    installed: ?RemotePluginInstalledItemPayload,
};

pub fn isKnownRemoteMarketplace(name: []const u8) bool {
    return std.mem.eql(u8, name, "chatgpt-global") or
        std.mem.eql(u8, name, "workspace-directory") or
        std.mem.eql(u8, name, "shared-with-me");
}

pub fn isValidRemotePluginId(plugin_id: []const u8) bool {
    if (plugin_id.len == 0) return false;
    for (plugin_id) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '~') continue;
        return false;
    }
    return true;
}

pub fn fetchReadJson(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    credentials: auth.Credentials,
    plugin_id: []const u8,
) ![]const u8 {
    const detail_url = try pluginDetailUrl(allocator, base_url, plugin_id);
    defer allocator.free(detail_url);
    const detail_body = try fetchJsonBytes(allocator, detail_url, credentials);
    defer allocator.free(detail_body);

    var detail_parse = try parsePluginDetail(allocator, detail_body, plugin_id);
    defer detail_parse.deinit();
    const scope = scopeFromApiValue(detail_parse.value.scope) orelse return error.RemotePluginInvalidScope;

    const installed_url = try installedPluginsUrl(allocator, base_url, scope);
    defer allocator.free(installed_url);
    const installed_body = try fetchJsonBytes(allocator, installed_url, credentials);
    defer allocator.free(installed_body);

    var installed_parse = try parseInstalledPlugins(allocator, installed_body);
    defer installed_parse.deinit();
    return renderReadJson(allocator, detail_parse.value, installed_parse.value, scope);
}

pub fn fetchSkillReadJson(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    credentials: auth.Credentials,
    plugin_id: []const u8,
    skill_name: []const u8,
) ![]const u8 {
    const url = try skillDetailUrl(allocator, base_url, plugin_id, skill_name);
    defer allocator.free(url);

    const bytes = try fetchJsonBytes(allocator, url, credentials);
    defer allocator.free(bytes);
    return renderSkillReadJson(allocator, bytes, plugin_id, skill_name);
}

pub fn fetchMarketplacesJson(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    credentials: auth.Credentials,
    sources: MarketplaceSources,
) ![]const u8 {
    var workspace_installed_pages: ?RemoteInstalledPluginPages = null;
    defer if (workspace_installed_pages) |*pages| deinitInstalledPluginPages(allocator, pages);
    if (sources.workspace_directory or sources.shared_with_me) {
        workspace_installed_pages = try fetchInstalledPluginPages(allocator, base_url, credentials, .workspace);
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "[");
    var marketplace_count: usize = 0;

    if (sources.global) {
        var directory_pages = try fetchPluginListPages(allocator, base_url, credentials, .{ .scoped = .global });
        defer deinitPluginListPages(allocator, &directory_pages);
        var installed_pages = try fetchInstalledPluginPages(allocator, base_url, credentials, .global);
        defer deinitInstalledPluginPages(allocator, &installed_pages);
        try appendRemoteMarketplaceJsonFromPages(
            allocator,
            &out,
            &marketplace_count,
            "chatgpt-global",
            "ChatGPT Plugins",
            .global,
            &directory_pages,
            &installed_pages,
            true,
        );
    }

    if (sources.workspace_directory) {
        var directory_pages = try fetchPluginListPages(allocator, base_url, credentials, .{ .scoped = .workspace });
        defer deinitPluginListPages(allocator, &directory_pages);
        if (workspace_installed_pages) |*installed_pages| {
            try appendRemoteMarketplaceJsonFromPages(
                allocator,
                &out,
                &marketplace_count,
                "workspace-directory",
                "Workspace Directory",
                .workspace,
                &directory_pages,
                installed_pages,
                false,
            );
        }
    }

    if (sources.shared_with_me) {
        var directory_pages = try fetchPluginListPages(allocator, base_url, credentials, .shared_workspace);
        defer deinitPluginListPages(allocator, &directory_pages);
        if (workspace_installed_pages) |*installed_pages| {
            try appendRemoteMarketplaceJsonFromPages(
                allocator,
                &out,
                &marketplace_count,
                "shared-with-me",
                "Shared with me",
                .workspace,
                &directory_pages,
                installed_pages,
                false,
            );
        }
    }

    try out.appendSlice(allocator, "]");
    return out.toOwnedSlice(allocator);
}

fn fetchJsonBytes(allocator: std.mem.Allocator, url: []const u8, credentials: auth.Credentials) ![]const u8 {
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    const auth_header = try auth.authorizationHeader(allocator, credentials);
    defer allocator.free(auth_header);
    try headers.append(allocator, .{ .name = "Authorization", .value = auth_header });
    try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "User-Agent", .value = "codex-zig-port/0.0.1" });
    if (credentials.account_id) |account_id| {
        try headers.append(allocator, .{ .name = "ChatGPT-Account-Id", .value = account_id });
    }
    if (credentials.fedramp) {
        try headers.append(allocator, .{ .name = "X-OpenAI-Fedramp", .value = "true" });
    }

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io_instance.io() };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_body.writer,
        .extra_headers = headers.items,
    });
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return error.RemotePluginHttpStatus;
    }

    return response_body.toOwnedSlice();
}

fn fetchPluginListPages(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    credentials: auth.Credentials,
    source: RemotePluginListSource,
) !RemotePluginListPages {
    var pages = RemotePluginListPages.empty;
    errdefer deinitPluginListPages(allocator, &pages);

    var next_page_token: ?[]const u8 = null;
    while (true) {
        const url = switch (source) {
            .scoped => |scope| try pluginListUrl(allocator, base_url, scope, next_page_token),
            .shared_workspace => try sharedWorkspacePluginsUrl(allocator, base_url, next_page_token),
        };
        defer allocator.free(url);
        const body = try fetchJsonBytes(allocator, url, credentials);
        defer allocator.free(body);

        var parsed = try std.json.parseFromSlice(RemotePluginListResponsePayload, allocator, body, .{ .ignore_unknown_fields = true });
        var appended = false;
        errdefer if (!appended) parsed.deinit();
        next_page_token = parsed.value.pagination.next_page_token;
        try pages.append(allocator, parsed);
        appended = true;
        if (next_page_token == null) break;
    }

    return pages;
}

fn fetchInstalledPluginPages(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    credentials: auth.Credentials,
    scope: RemotePluginScope,
) !RemoteInstalledPluginPages {
    var pages = RemoteInstalledPluginPages.empty;
    errdefer deinitInstalledPluginPages(allocator, &pages);

    var next_page_token: ?[]const u8 = null;
    while (true) {
        const url = try installedPluginsPageUrl(allocator, base_url, scope, next_page_token);
        defer allocator.free(url);
        const body = try fetchJsonBytes(allocator, url, credentials);
        defer allocator.free(body);

        var parsed = try std.json.parseFromSlice(RemotePluginInstalledResponsePayload, allocator, body, .{ .ignore_unknown_fields = true });
        var appended = false;
        errdefer if (!appended) parsed.deinit();
        next_page_token = parsed.value.pagination.next_page_token;
        try pages.append(allocator, parsed);
        appended = true;
        if (next_page_token == null) break;
    }

    return pages;
}

fn deinitPluginListPages(allocator: std.mem.Allocator, pages: *RemotePluginListPages) void {
    for (pages.items) |*page| page.deinit();
    pages.deinit(allocator);
}

fn deinitInstalledPluginPages(allocator: std.mem.Allocator, pages: *RemoteInstalledPluginPages) void {
    for (pages.items) |*page| page.deinit();
    pages.deinit(allocator);
}

fn pluginDetailUrl(allocator: std.mem.Allocator, base_url: []const u8, plugin_id: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (trimmed.len == 0) return error.InvalidRemotePluginBaseUrl;

    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);
    try url.appendSlice(allocator, trimmed);
    try url.appendSlice(allocator, "/ps/plugins/");
    try appendPathSegment(allocator, &url, plugin_id);
    return url.toOwnedSlice(allocator);
}

fn pluginListUrl(allocator: std.mem.Allocator, base_url: []const u8, scope: RemotePluginScope, page_token: ?[]const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (trimmed.len == 0) return error.InvalidRemotePluginBaseUrl;

    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);
    try url.appendSlice(allocator, trimmed);
    try url.appendSlice(allocator, "/ps/plugins/list?scope=");
    try url.appendSlice(allocator, scopeApiValue(scope));
    try url.appendSlice(allocator, "&limit=200");
    if (page_token) |token| {
        try url.appendSlice(allocator, "&pageToken=");
        try appendPathSegment(allocator, &url, token);
    }
    return url.toOwnedSlice(allocator);
}

fn sharedWorkspacePluginsUrl(allocator: std.mem.Allocator, base_url: []const u8, page_token: ?[]const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (trimmed.len == 0) return error.InvalidRemotePluginBaseUrl;

    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);
    try url.appendSlice(allocator, trimmed);
    try url.appendSlice(allocator, "/ps/plugins/workspace/shared?limit=200");
    if (page_token) |token| {
        try url.appendSlice(allocator, "&pageToken=");
        try appendPathSegment(allocator, &url, token);
    }
    return url.toOwnedSlice(allocator);
}

fn installedPluginsUrl(allocator: std.mem.Allocator, base_url: []const u8, scope: RemotePluginScope) ![]const u8 {
    return installedPluginsPageUrl(allocator, base_url, scope, null);
}

fn installedPluginsPageUrl(allocator: std.mem.Allocator, base_url: []const u8, scope: RemotePluginScope, page_token: ?[]const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (trimmed.len == 0) return error.InvalidRemotePluginBaseUrl;

    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);
    try url.appendSlice(allocator, trimmed);
    try url.appendSlice(allocator, "/ps/plugins/installed?scope=");
    try url.appendSlice(allocator, scopeApiValue(scope));
    if (page_token) |token| {
        try url.appendSlice(allocator, "&pageToken=");
        try appendPathSegment(allocator, &url, token);
    }
    return url.toOwnedSlice(allocator);
}

fn skillDetailUrl(allocator: std.mem.Allocator, base_url: []const u8, plugin_id: []const u8, skill_name: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (trimmed.len == 0) return error.InvalidRemotePluginBaseUrl;

    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);
    try url.appendSlice(allocator, trimmed);
    try url.appendSlice(allocator, "/ps/plugins/");
    try appendPathSegment(allocator, &url, plugin_id);
    try url.appendSlice(allocator, "/skills/");
    try appendPathSegment(allocator, &url, skill_name);
    return url.toOwnedSlice(allocator);
}

fn appendPathSegment(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (isUnreservedUrlByte(byte)) {
            try out.append(allocator, byte);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[byte >> 4]);
            try out.append(allocator, hex[byte & 0x0f]);
        }
    }
}

fn isUnreservedUrlByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

fn parsePluginDetail(allocator: std.mem.Allocator, body: []const u8, expected_plugin_id: []const u8) !std.json.Parsed(RemotePluginDetailPayload) {
    var parsed = try std.json.parseFromSlice(RemotePluginDetailPayload, allocator, body, .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.id, expected_plugin_id)) return error.RemotePluginPluginIdMismatch;
    if (scopeFromApiValue(parsed.value.scope) == null) return error.RemotePluginInvalidScope;
    return parsed;
}

fn parseInstalledPlugins(allocator: std.mem.Allocator, body: []const u8) !std.json.Parsed(RemotePluginInstalledResponsePayload) {
    return std.json.parseFromSlice(RemotePluginInstalledResponsePayload, allocator, body, .{ .ignore_unknown_fields = true });
}

fn renderReadJson(
    allocator: std.mem.Allocator,
    detail: RemotePluginDetailPayload,
    installed_response: RemotePluginInstalledResponsePayload,
    scope: RemotePluginScope,
) ![]const u8 {
    const installed_plugin = findInstalledPlugin(installed_response.plugins, detail.id);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"plugin\":{\"marketplaceName\":");
    try appendJsonString(allocator, &out, marketplaceName(scope));
    try out.appendSlice(allocator, ",\"marketplacePath\":null,\"summary\":");
    try appendRemotePluginSummaryJson(allocator, &out, detail, scope, installed_plugin);
    try out.appendSlice(allocator, ",\"description\":");
    try appendOptionalStringJson(allocator, &out, nonEmptyString(detail.release.description));
    try out.appendSlice(allocator, ",\"skills\":");
    try appendRemotePluginSkillsJson(allocator, &out, detail.release.skills, installed_plugin);
    try out.appendSlice(allocator, ",\"hooks\":[],\"apps\":");
    try appendRemotePluginAppsJson(allocator, &out, detail.release.app_ids);
    try out.appendSlice(allocator, ",\"mcpServers\":[]}}");
    return out.toOwnedSlice(allocator);
}

fn appendRemotePluginSummaryJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    detail: RemotePluginDetailPayload,
    scope: RemotePluginScope,
    installed_plugin: ?RemotePluginInstalledItemPayload,
) !void {
    try out.appendSlice(allocator, "{\"id\":");
    try appendJsonString(allocator, out, detail.id);
    try out.appendSlice(allocator, ",\"name\":");
    try appendJsonString(allocator, out, detail.name);
    try out.appendSlice(allocator, ",\"shareContext\":");
    try appendRemoteShareContextJson(allocator, out, detail, scope);
    try out.appendSlice(allocator, ",\"source\":{\"type\":\"remote\"},\"installed\":");
    try appendBool(allocator, out, installed_plugin != null);
    try out.appendSlice(allocator, ",\"enabled\":");
    try appendBool(allocator, out, if (installed_plugin) |plugin| plugin.enabled else false);
    try out.appendSlice(allocator, ",\"installPolicy\":");
    try appendJsonString(allocator, out, try normalizedInstallPolicy(detail.installation_policy));
    try out.appendSlice(allocator, ",\"authPolicy\":");
    try appendJsonString(allocator, out, try normalizedAuthPolicy(detail.authentication_policy));
    try out.appendSlice(allocator, ",\"availability\":");
    try appendJsonString(allocator, out, try normalizedAvailability(detail.status));
    try out.appendSlice(allocator, ",\"interface\":");
    try appendRemotePluginInterfaceJson(allocator, out, detail.release);
    try out.appendSlice(allocator, ",\"keywords\":");
    try appendStringArrayJson(allocator, out, detail.release.keywords);
    try out.appendSlice(allocator, "}");
}

fn appendRemoteMarketplaceJsonFromPages(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    marketplace_count: *usize,
    marketplace_name_value: []const u8,
    display_name: []const u8,
    scope: RemotePluginScope,
    directory_pages: *const RemotePluginListPages,
    installed_pages: *const RemoteInstalledPluginPages,
    include_installed_only: bool,
) !void {
    var entries = std.ArrayList(RemoteMarketplacePluginEntry).empty;
    defer entries.deinit(allocator);

    for (directory_pages.items) |page| {
        if (page.value.plugins) |plugins| {
            for (plugins) |plugin| {
                const installed_plugin = findInstalledPluginInPages(installed_pages, plugin.id);
                if (indexOfRemoteMarketplaceEntry(entries.items, plugin.id)) |index| {
                    entries.items[index] = .{ .detail = plugin, .scope = scope, .installed = installed_plugin };
                } else {
                    try entries.append(allocator, .{ .detail = plugin, .scope = scope, .installed = installed_plugin });
                }
            }
        }
    }

    if (include_installed_only) {
        for (installed_pages.items) |page| {
            if (page.value.plugins) |plugins| {
                for (plugins) |installed_plugin| {
                    if (indexOfRemoteMarketplaceEntry(entries.items, installed_plugin.id) != null) continue;
                    const detail = installedPluginAsDetail(installed_plugin) orelse continue;
                    try entries.append(allocator, .{ .detail = detail, .scope = scope, .installed = installed_plugin });
                }
            }
        }
    }

    if (entries.items.len == 0) return;
    std.mem.sort(RemoteMarketplacePluginEntry, entries.items, {}, remoteMarketplaceEntryLessThan);

    try appendCommaIfNeeded(allocator, out, marketplace_count);
    try out.appendSlice(allocator, "{\"name\":");
    try appendJsonString(allocator, out, marketplace_name_value);
    try out.appendSlice(allocator, ",\"path\":null,\"interface\":{\"displayName\":");
    try appendJsonString(allocator, out, display_name);
    try out.appendSlice(allocator, "},\"plugins\":[");
    for (entries.items, 0..) |entry, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try appendRemotePluginSummaryJson(allocator, out, entry.detail, entry.scope, entry.installed);
    }
    try out.appendSlice(allocator, "]}");
}

fn appendRemoteShareContextJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    detail: RemotePluginDetailPayload,
    scope: RemotePluginScope,
) !void {
    if (scope == .global) {
        try out.appendSlice(allocator, "null");
        return;
    }

    try out.appendSlice(allocator, "{\"remotePluginId\":");
    try appendJsonString(allocator, out, detail.id);
    try out.appendSlice(allocator, ",\"shareUrl\":");
    try appendOptionalStringJson(allocator, out, detail.share_url);
    try out.appendSlice(allocator, ",\"creatorAccountUserId\":");
    try appendOptionalStringJson(allocator, out, detail.creator_account_user_id);
    try out.appendSlice(allocator, ",\"creatorName\":");
    try appendOptionalStringJson(allocator, out, detail.creator_name);
    try out.appendSlice(allocator, ",\"shareTargets\":");
    try appendRemoteShareTargetsJson(allocator, out, detail.share_principals);
    try out.appendSlice(allocator, "}");
}

fn appendRemoteShareTargetsJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    principals: ?[]const RemotePluginSharePrincipalPayload,
) !void {
    const values = principals orelse {
        try out.appendSlice(allocator, "null");
        return;
    };

    try out.appendSlice(allocator, "[");
    var count: usize = 0;
    for (values) |principal| {
        if (!std.mem.eql(u8, principal.role orelse "", "reader")) continue;
        try appendCommaIfNeeded(allocator, out, &count);
        try out.appendSlice(allocator, "{\"principalType\":");
        try appendJsonString(allocator, out, principal.principal_type);
        try out.appendSlice(allocator, ",\"principalId\":");
        try appendJsonString(allocator, out, principal.principal_id);
        try out.appendSlice(allocator, ",\"name\":");
        try appendJsonString(allocator, out, principal.name);
        try out.appendSlice(allocator, "}");
    }
    try out.appendSlice(allocator, "]");
}

fn appendRemotePluginInterfaceJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    release: RemotePluginReleasePayload,
) !void {
    const interface = release.interface;
    const display_name = nonEmptyString(release.display_name);
    const default_prompt = normalizedDefaultPrompt(interface.default_prompt);
    if (display_name == null and
        interface.short_description == null and
        interface.long_description == null and
        interface.developer_name == null and
        interface.category == null and
        !stringArrayHasValues(interface.capabilities) and
        interface.website_url == null and
        interface.privacy_policy_url == null and
        interface.terms_of_service_url == null and
        default_prompt == null and
        interface.brand_color == null and
        interface.composer_icon_url == null and
        interface.logo_url == null and
        !stringArrayHasValues(interface.screenshot_urls))
    {
        try out.appendSlice(allocator, "null");
        return;
    }

    try out.appendSlice(allocator, "{");
    try appendNamedOptionalString(allocator, out, "displayName", display_name);
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "shortDescription", interface.short_description);
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "longDescription", interface.long_description);
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "developerName", interface.developer_name);
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "category", interface.category);
    try out.appendSlice(allocator, ",\"capabilities\":");
    try appendStringArrayJson(allocator, out, interface.capabilities);
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "websiteUrl", interface.website_url);
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "privacyPolicyUrl", interface.privacy_policy_url);
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "termsOfServiceUrl", interface.terms_of_service_url);
    try out.appendSlice(allocator, ",\"defaultPrompt\":");
    try appendDefaultPromptJson(allocator, out, default_prompt);
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "brandColor", interface.brand_color);
    try out.appendSlice(allocator, ",\"composerIcon\":null,\"composerIconUrl\":");
    try appendOptionalStringJson(allocator, out, interface.composer_icon_url);
    try out.appendSlice(allocator, ",\"logo\":null,\"logoUrl\":");
    try appendOptionalStringJson(allocator, out, interface.logo_url);
    try out.appendSlice(allocator, ",\"screenshots\":[],\"screenshotUrls\":");
    try appendStringArrayJson(allocator, out, interface.screenshot_urls);
    try out.appendSlice(allocator, "}");
}

fn appendRemotePluginSkillsJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    skills_opt: ?[]const RemotePluginSkillPayload,
    installed_plugin: ?RemotePluginInstalledItemPayload,
) !void {
    const skills = skills_opt orelse {
        try out.appendSlice(allocator, "[]");
        return;
    };
    const disabled_skill_names = if (installed_plugin) |plugin| plugin.disabled_skill_names else null;

    try out.appendSlice(allocator, "[");
    for (skills, 0..) |skill, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "{\"name\":");
        try appendJsonString(allocator, out, skill.name);
        try out.appendSlice(allocator, ",\"description\":");
        try appendJsonString(allocator, out, skill.description);
        try out.appendSlice(allocator, ",\"shortDescription\":");
        try appendOptionalStringJson(allocator, out, if (skill.interface) |interface| interface.short_description else null);
        try out.appendSlice(allocator, ",\"interface\":");
        try appendRemoteSkillInterfaceJson(allocator, out, skill.interface);
        try out.appendSlice(allocator, ",\"path\":null,\"enabled\":");
        try appendBool(allocator, out, !containsString(disabled_skill_names, skill.name));
        try out.appendSlice(allocator, "}");
    }
    try out.appendSlice(allocator, "]");
}

fn appendRemoteSkillInterfaceJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    interface_opt: ?RemotePluginSkillInterfacePayload,
) !void {
    const interface = interface_opt orelse {
        try out.appendSlice(allocator, "null");
        return;
    };
    if (interface.display_name == null and
        interface.short_description == null and
        interface.brand_color == null and
        interface.default_prompt == null)
    {
        try out.appendSlice(allocator, "null");
        return;
    }

    try out.appendSlice(allocator, "{");
    try appendNamedOptionalString(allocator, out, "displayName", interface.display_name);
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "shortDescription", interface.short_description);
    try out.appendSlice(allocator, ",\"iconSmall\":null,\"iconLarge\":null,");
    try appendNamedOptionalString(allocator, out, "brandColor", interface.brand_color);
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "defaultPrompt", interface.default_prompt);
    try out.appendSlice(allocator, "}");
}

fn appendRemotePluginAppsJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    app_ids_opt: ?[]const []const u8,
) !void {
    const app_ids = app_ids_opt orelse {
        try out.appendSlice(allocator, "[]");
        return;
    };

    try out.appendSlice(allocator, "[");
    for (app_ids, 0..) |app_id, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        const install_url = try std.fmt.allocPrint(allocator, "https://chatgpt.com/apps/{s}/{s}", .{ app_id, app_id });
        defer allocator.free(install_url);
        try out.appendSlice(allocator, "{\"id\":");
        try appendJsonString(allocator, out, app_id);
        try out.appendSlice(allocator, ",\"name\":");
        try appendJsonString(allocator, out, app_id);
        try out.appendSlice(allocator, ",\"description\":null,\"installUrl\":");
        try appendJsonString(allocator, out, install_url);
        try out.appendSlice(allocator, ",\"needsAuth\":true}");
    }
    try out.appendSlice(allocator, "]");
}

fn renderSkillReadJson(allocator: std.mem.Allocator, body: []const u8, expected_plugin_id: []const u8, expected_skill_name: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(RemotePluginSkillDetailPayload, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.plugin_id, expected_plugin_id)) return error.RemotePluginSkillPluginIdMismatch;
    if (!std.mem.eql(u8, parsed.value.name, expected_skill_name)) return error.RemotePluginSkillNameMismatch;

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, "{\"contents\":");
    if (parsed.value.skill_md_contents) |contents| {
        const contents_json = try std.json.Stringify.valueAlloc(allocator, contents, .{});
        defer allocator.free(contents_json);
        try result.appendSlice(allocator, contents_json);
    } else {
        try result.appendSlice(allocator, "null");
    }
    try result.appendSlice(allocator, "}");
    return result.toOwnedSlice(allocator);
}

fn findInstalledPlugin(plugins_opt: ?[]const RemotePluginInstalledItemPayload, plugin_id: []const u8) ?RemotePluginInstalledItemPayload {
    const plugins = plugins_opt orelse return null;
    for (plugins) |plugin| {
        if (std.mem.eql(u8, plugin.id, plugin_id)) return plugin;
    }
    return null;
}

fn findInstalledPluginInPages(installed_pages: *const RemoteInstalledPluginPages, plugin_id: []const u8) ?RemotePluginInstalledItemPayload {
    for (installed_pages.items) |page| {
        if (page.value.plugins) |plugins| {
            if (findInstalledPlugin(plugins, plugin_id)) |plugin| return plugin;
        }
    }
    return null;
}

fn installedPluginAsDetail(installed_plugin: RemotePluginInstalledItemPayload) ?RemotePluginDetailPayload {
    const name = installed_plugin.name orelse return null;
    const scope = installed_plugin.scope orelse return null;
    const installation_policy = installed_plugin.installation_policy orelse return null;
    const authentication_policy = installed_plugin.authentication_policy orelse return null;
    const release = installed_plugin.release orelse return null;
    if (scopeFromApiValue(scope) == null) return null;
    return .{
        .id = installed_plugin.id,
        .name = name,
        .scope = scope,
        .creator_account_user_id = installed_plugin.creator_account_user_id,
        .creator_name = installed_plugin.creator_name,
        .share_url = installed_plugin.share_url,
        .share_principals = installed_plugin.share_principals,
        .installation_policy = installation_policy,
        .authentication_policy = authentication_policy,
        .status = installed_plugin.status,
        .release = release,
    };
}

fn indexOfRemoteMarketplaceEntry(entries: []const RemoteMarketplacePluginEntry, plugin_id: []const u8) ?usize {
    for (entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.detail.id, plugin_id)) return index;
    }
    return null;
}

fn remoteMarketplaceEntryLessThan(_: void, left: RemoteMarketplacePluginEntry, right: RemoteMarketplacePluginEntry) bool {
    const left_name = remotePluginDisplayName(left.detail);
    const right_name = remotePluginDisplayName(right.detail);
    const lower_order = asciiLowerOrder(left_name, right_name);
    if (lower_order != .eq) return lower_order == .lt;
    const display_order = std.mem.order(u8, left_name, right_name);
    if (display_order != .eq) return display_order == .lt;
    return std.mem.lessThan(u8, left.detail.id, right.detail.id);
}

fn remotePluginDisplayName(detail: RemotePluginDetailPayload) []const u8 {
    return nonEmptyString(detail.release.display_name) orelse detail.name;
}

fn asciiLowerOrder(left: []const u8, right: []const u8) std.math.Order {
    const len = @min(left.len, right.len);
    for (left[0..len], right[0..len]) |left_byte, right_byte| {
        const left_lower = std.ascii.toLower(left_byte);
        const right_lower = std.ascii.toLower(right_byte);
        if (left_lower < right_lower) return .lt;
        if (left_lower > right_lower) return .gt;
    }
    if (left.len < right.len) return .lt;
    if (left.len > right.len) return .gt;
    return .eq;
}

fn scopeFromApiValue(value: []const u8) ?RemotePluginScope {
    if (std.mem.eql(u8, value, "GLOBAL")) return .global;
    if (std.mem.eql(u8, value, "WORKSPACE")) return .workspace;
    return null;
}

fn scopeApiValue(scope: RemotePluginScope) []const u8 {
    return switch (scope) {
        .global => "GLOBAL",
        .workspace => "WORKSPACE",
    };
}

fn marketplaceName(scope: RemotePluginScope) []const u8 {
    return switch (scope) {
        .global => "chatgpt-global",
        .workspace => "workspace-directory",
    };
}

fn normalizedInstallPolicy(value: []const u8) ![]const u8 {
    if (std.mem.eql(u8, value, "NOT_AVAILABLE")) return "NOT_AVAILABLE";
    if (std.mem.eql(u8, value, "AVAILABLE")) return "AVAILABLE";
    if (std.mem.eql(u8, value, "INSTALLED_BY_DEFAULT")) return "INSTALLED_BY_DEFAULT";
    return error.RemotePluginInvalidInstallPolicy;
}

fn normalizedAuthPolicy(value: []const u8) ![]const u8 {
    if (std.mem.eql(u8, value, "ON_INSTALL")) return "ON_INSTALL";
    if (std.mem.eql(u8, value, "ON_USE")) return "ON_USE";
    return error.RemotePluginInvalidAuthPolicy;
}

fn normalizedAvailability(value_opt: ?[]const u8) ![]const u8 {
    const value = value_opt orelse return "AVAILABLE";
    if (std.mem.eql(u8, value, "AVAILABLE")) return "AVAILABLE";
    if (std.mem.eql(u8, value, "ENABLED")) return "AVAILABLE";
    if (std.mem.eql(u8, value, "DISABLED_BY_ADMIN")) return "DISABLED_BY_ADMIN";
    return error.RemotePluginInvalidAvailability;
}

fn normalizedDefaultPrompt(value_opt: ?[]const u8) ?[]const u8 {
    const value = value_opt orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    const char_count = std.unicode.utf8CountCodepoints(trimmed) catch trimmed.len;
    if (char_count > MAX_REMOTE_DEFAULT_PROMPT_LEN) return null;
    return trimmed;
}

fn nonEmptyString(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn appendNamedOptionalString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: ?[]const u8) !void {
    try appendJsonString(allocator, out, name);
    try out.appendSlice(allocator, ":");
    try appendOptionalStringJson(allocator, out, value);
}

fn appendOptionalStringJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: ?[]const u8) !void {
    if (value) |string| {
        try appendJsonString(allocator, out, string);
    } else {
        try out.appendSlice(allocator, "null");
    }
}

fn appendStringArrayJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), values_opt: ?[]const []const u8) !void {
    const values = values_opt orelse {
        try out.appendSlice(allocator, "[]");
        return;
    };
    try out.appendSlice(allocator, "[");
    for (values, 0..) |value, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try appendJsonString(allocator, out, value);
    }
    try out.appendSlice(allocator, "]");
}

fn appendDefaultPromptJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: ?[]const u8) !void {
    if (value) |prompt| {
        try out.appendSlice(allocator, "[");
        try appendJsonString(allocator, out, prompt);
        try out.appendSlice(allocator, "]");
    } else {
        try out.appendSlice(allocator, "null");
    }
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    try out.appendSlice(allocator, encoded);
}

fn appendBool(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: bool) !void {
    try out.appendSlice(allocator, if (value) "true" else "false");
}

fn appendCommaIfNeeded(allocator: std.mem.Allocator, out: *std.ArrayList(u8), count: *usize) !void {
    if (count.* > 0) try out.appendSlice(allocator, ",");
    count.* += 1;
}

fn containsString(values_opt: ?[]const []const u8, needle: []const u8) bool {
    const values = values_opt orelse return false;
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn stringArrayHasValues(values_opt: ?[]const []const u8) bool {
    const values = values_opt orelse return false;
    return values.len > 0;
}

test "remote plugin id validation follows Rust wire shape" {
    try std.testing.expect(isValidRemotePluginId("plugins~Plugin_00000000000000000000000000000000"));
    try std.testing.expect(isValidRemotePluginId("plugin-123"));
    try std.testing.expect(!isValidRemotePluginId(""));
    try std.testing.expect(!isValidRemotePluginId("plugin/123"));
}

test "remote plugin detail URLs match backend catalog paths" {
    const allocator = std.testing.allocator;
    const detail_url = try pluginDetailUrl(allocator, "https://chatgpt.com/backend-api/", "plugins~Plugin_123");
    defer allocator.free(detail_url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/ps/plugins/plugins~Plugin_123", detail_url);

    const installed_url = try installedPluginsUrl(allocator, "https://chatgpt.com/backend-api/", .global);
    defer allocator.free(installed_url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/ps/plugins/installed?scope=GLOBAL", installed_url);
}

test "remote plugin read JSON maps installed detail state" {
    const allocator = std.testing.allocator;
    const detail_body =
        \\{
        \\  "id": "plugins~Plugin_123",
        \\  "name": "linear",
        \\  "scope": "GLOBAL",
        \\  "installation_policy": "AVAILABLE",
        \\  "authentication_policy": "ON_USE",
        \\  "status": "ENABLED",
        \\  "release": {
        \\    "display_name": "Linear",
        \\    "description": " Track work in Linear ",
        \\    "app_ids": ["gmail"],
        \\    "keywords": ["issue-tracking"],
        \\    "interface": {
        \\      "short_description": "Plan and track work",
        \\      "capabilities": ["Read"],
        \\      "logo_url": "https://example.com/logo.png",
        \\      "screenshot_urls": ["https://example.com/shot.png"]
        \\    },
        \\    "skills": [
        \\      {
        \\        "name": "plan-work",
        \\        "description": "Plan work",
        \\        "interface": {"display_name": "Plan Work", "short_description": "Create a plan"}
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const installed_body =
        \\{
        \\  "plugins": [
        \\    {"id": "plugins~Plugin_123", "enabled": false, "disabled_skill_names": ["plan-work"]}
        \\  ],
        \\  "pagination": {"next_page_token": null}
        \\}
    ;
    var detail_parse = try parsePluginDetail(allocator, detail_body, "plugins~Plugin_123");
    defer detail_parse.deinit();
    var installed_parse = try parseInstalledPlugins(allocator, installed_body);
    defer installed_parse.deinit();
    const rendered = try renderReadJson(allocator, detail_parse.value, installed_parse.value, .global);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"source\":{\"type\":\"remote\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"installed\":true,\"enabled\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"description\":\"Track work in Linear\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"path\":null,\"enabled\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"apps\":[{\"id\":\"gmail\",\"name\":\"gmail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"availability\":\"AVAILABLE\"") != null);
}

test "remote plugin read JSON returns workspace share context readers" {
    const allocator = std.testing.allocator;
    const detail_body =
        \\{
        \\  "id": "plugins~Plugin_456",
        \\  "name": "shared-linear",
        \\  "scope": "WORKSPACE",
        \\  "creator_account_user_id": "user-owner",
        \\  "creator_name": "Owner",
        \\  "share_url": "https://chatgpt.example/share",
        \\  "share_principals": [
        \\    {"principal_type": "user", "principal_id": "user-owner", "role": "owner", "name": "Owner"},
        \\    {"principal_type": "user", "principal_id": "user-reader", "role": "reader", "name": "Reader"}
        \\  ],
        \\  "installation_policy": "AVAILABLE",
        \\  "authentication_policy": "ON_USE",
        \\  "release": {
        \\    "display_name": "Shared Linear",
        \\    "description": "",
        \\    "app_ids": [],
        \\    "keywords": [],
        \\    "interface": {},
        \\    "skills": []
        \\  }
        \\}
    ;
    const installed_body =
        \\{"plugins":[],"pagination":{"next_page_token":null}}
    ;
    var detail_parse = try parsePluginDetail(allocator, detail_body, "plugins~Plugin_456");
    defer detail_parse.deinit();
    var installed_parse = try parseInstalledPlugins(allocator, installed_body);
    defer installed_parse.deinit();
    const rendered = try renderReadJson(allocator, detail_parse.value, installed_parse.value, .workspace);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"marketplaceName\":\"workspace-directory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"shareTargets\":[{\"principalType\":\"user\",\"principalId\":\"user-reader\",\"name\":\"Reader\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "user-owner\",\"name\":\"Owner\"") == null);
}

test "remote skill detail URL appends escaped path segments" {
    const allocator = std.testing.allocator;
    const url = try skillDetailUrl(allocator, "https://chatgpt.com/backend-api/", "plugins~Plugin_123", "plan work");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/ps/plugins/plugins~Plugin_123/skills/plan%20work", url);
}

test "remote skill detail JSON renders nullable contents" {
    const allocator = std.testing.allocator;
    const body =
        \\{"plugin_id":"plugins~Plugin_123","name":"plan-work","skill_md_contents":"# Plan Work\n"}
    ;
    const rendered = try renderSkillReadJson(allocator, body, "plugins~Plugin_123", "plan-work");
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("{\"contents\":\"# Plan Work\\n\"}", rendered);

    const null_body =
        \\{"plugin_id":"plugins~Plugin_123","name":"plan-work","skill_md_contents":null}
    ;
    const null_rendered = try renderSkillReadJson(allocator, null_body, "plugins~Plugin_123", "plan-work");
    defer allocator.free(null_rendered);
    try std.testing.expectEqualStrings("{\"contents\":null}", null_rendered);
}
