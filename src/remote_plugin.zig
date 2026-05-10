const std = @import("std");

const auth = @import("auth.zig");

const MAX_REMOTE_DEFAULT_PROMPT_LEN = 128;
const REMOTE_PLUGIN_SHARE_MAX_ARCHIVE_BYTES = 50 * 1024 * 1024;

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
    limit: ?usize = null,
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

const RemotePluginMutationResponsePayload = struct {
    id: []const u8,
    enabled: bool,
};

pub const InstallResult = struct {
    response_json: []const u8,
    installed_path: []const u8,

    pub fn deinit(self: InstallResult, allocator: std.mem.Allocator) void {
        allocator.free(self.response_json);
        allocator.free(self.installed_path);
    }
};

const RemotePluginShareUpdateTargetsResponsePayload = struct {
    principals: []const RemotePluginSharePrincipalPayload,
};

const RemoteWorkspacePluginUploadUrlResponsePayload = struct {
    file_id: []const u8,
    upload_url: []const u8,
    etag: ?[]const u8 = null,
};

const RemoteWorkspacePluginCreateResponsePayload = struct {
    plugin_id: []const u8,
    share_url: ?[]const u8 = null,
};

const ArchiveTreeEntry = struct {
    name: []u8,
    kind: std.Io.File.Kind,
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

pub fn uninstall(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    credentials: auth.Credentials,
    codex_home: []const u8,
    plugin_id: []const u8,
) !void {
    const detail_url = try pluginDetailUrl(allocator, base_url, plugin_id);
    defer allocator.free(detail_url);
    const detail_body = try fetchJsonBytes(allocator, detail_url, credentials);
    defer allocator.free(detail_body);

    var detail_parse = try parsePluginDetail(allocator, detail_body, plugin_id);
    defer detail_parse.deinit();
    const scope = scopeFromApiValue(detail_parse.value.scope) orelse return error.RemotePluginInvalidScope;

    const uninstall_url = try uninstallPluginUrl(allocator, base_url, plugin_id);
    defer allocator.free(uninstall_url);
    const uninstall_body = try sendJsonBytes(allocator, uninstall_url, .POST, credentials);
    defer allocator.free(uninstall_body);

    var mutation_parse = try std.json.parseFromSlice(RemotePluginMutationResponsePayload, allocator, uninstall_body, .{ .ignore_unknown_fields = true });
    defer mutation_parse.deinit();
    if (!std.mem.eql(u8, mutation_parse.value.id, plugin_id)) return error.RemotePluginPluginIdMismatch;
    if (mutation_parse.value.enabled) return error.RemotePluginUnexpectedEnabledState;

    try removeRemotePluginCache(allocator, codex_home, marketplaceName(scope), detail_parse.value.name, plugin_id);
}

pub fn install(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    credentials: auth.Credentials,
    codex_home: []const u8,
    plugin_id: []const u8,
) !InstallResult {
    const detail_url = try pluginDetailWithDownloadUrlsUrl(allocator, base_url, plugin_id);
    defer allocator.free(detail_url);
    const detail_body = try fetchJsonBytes(allocator, detail_url, credentials);
    defer allocator.free(detail_body);

    var detail_parse = try parsePluginDetail(allocator, detail_body, plugin_id);
    defer detail_parse.deinit();
    const detail = detail_parse.value;
    const scope = scopeFromApiValue(detail.scope) orelse return error.RemotePluginInvalidScope;
    const marketplace_name_value = marketplaceName(scope);

    const availability = try normalizedAvailability(detail.status);
    if (std.mem.eql(u8, availability, "DISABLED_BY_ADMIN")) return error.RemotePluginDisabledByAdmin;
    const install_policy = try normalizedInstallPolicy(detail.installation_policy);
    if (std.mem.eql(u8, install_policy, "NOT_AVAILABLE")) return error.RemotePluginNotAvailable;

    const version = detail.release.version orelse return error.RemotePluginMissingReleaseVersion;
    const bundle_url = detail.release.bundle_download_url orelse return error.RemotePluginMissingBundleDownloadUrl;
    if (!isRemoteBundleDownloadUrlAllowed(bundle_url)) return error.RemotePluginInsecureBundleDownloadUrl;

    const bundle = try fetchBytes(allocator, bundle_url, REMOTE_PLUGIN_SHARE_MAX_ARCHIVE_BYTES);
    defer allocator.free(bundle);

    const installed_path = try installRemotePluginBundle(
        allocator,
        codex_home,
        marketplace_name_value,
        detail.name,
        version,
        bundle,
    );
    errdefer allocator.free(installed_path);

    const install_url = try installPluginUrl(allocator, base_url, plugin_id);
    defer allocator.free(install_url);
    const install_body = try sendJsonBytes(allocator, install_url, .POST, credentials);
    defer allocator.free(install_body);

    var mutation_parse = try std.json.parseFromSlice(RemotePluginMutationResponsePayload, allocator, install_body, .{ .ignore_unknown_fields = true });
    defer mutation_parse.deinit();
    if (!std.mem.eql(u8, mutation_parse.value.id, plugin_id)) return error.RemotePluginPluginIdMismatch;
    if (!mutation_parse.value.enabled) return error.RemotePluginUnexpectedEnabledState;

    const response_json = try renderInstallResponseJson(allocator, try normalizedAuthPolicy(detail.authentication_policy));
    errdefer allocator.free(response_json);
    return .{
        .response_json = response_json,
        .installed_path = installed_path,
    };
}

pub fn fetchShareListJson(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    credentials: auth.Credentials,
    codex_home: []const u8,
) ![]const u8 {
    var created_pages = try fetchCreatedWorkspacePluginPages(allocator, base_url, credentials);
    defer deinitPluginListPages(allocator, &created_pages);

    var installed_pages = try fetchInstalledPluginPages(allocator, base_url, credentials, .workspace);
    defer deinitInstalledPluginPages(allocator, &installed_pages);

    var local_paths = try loadPluginShareLocalPaths(allocator, codex_home);
    defer local_paths.deinit();

    return renderShareListJson(allocator, &created_pages, &installed_pages, local_paths);
}

pub fn saveShareJson(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    credentials: auth.Credentials,
    codex_home: []const u8,
    plugin_path: []const u8,
    remote_plugin_id: ?[]const u8,
    discoverability: ?[]const u8,
    share_targets: ?[]const std.json.Value,
) ![]const u8 {
    const archive = try archivePluginForUpload(allocator, plugin_path);
    defer allocator.free(archive);

    const filename = try archiveFilename(allocator, plugin_path);
    defer allocator.free(filename);

    const upload_url = try workspacePluginUploadUrl(allocator, base_url);
    defer allocator.free(upload_url);
    const upload_payload = try renderWorkspacePluginUploadUrlRequestJson(allocator, filename, archive.len, remote_plugin_id);
    defer allocator.free(upload_payload);
    const upload_body = try sendJsonBytesWithPayload(allocator, upload_url, .POST, credentials, upload_payload);
    defer allocator.free(upload_body);

    var upload_parse = try std.json.parseFromSlice(RemoteWorkspacePluginUploadUrlResponsePayload, allocator, upload_body, .{
        .ignore_unknown_fields = true,
    });
    defer upload_parse.deinit();
    const etag = upload_parse.value.etag orelse return error.RemotePluginMissingUploadEtag;

    try putWorkspacePluginUpload(allocator, upload_parse.value.upload_url, archive);

    const finalize_url = try workspacePluginFinalizeUrl(allocator, base_url, remote_plugin_id);
    defer allocator.free(finalize_url);
    const finalize_payload = try renderWorkspacePluginCreateRequestJson(allocator, upload_parse.value.file_id, etag, discoverability, share_targets);
    defer allocator.free(finalize_payload);
    const finalize_body = try sendJsonBytesWithPayload(allocator, finalize_url, .POST, credentials, finalize_payload);
    defer allocator.free(finalize_body);

    var finalize_parse = try std.json.parseFromSlice(RemoteWorkspacePluginCreateResponsePayload, allocator, finalize_body, .{
        .ignore_unknown_fields = true,
    });
    defer finalize_parse.deinit();
    if (finalize_parse.value.plugin_id.len == 0) return error.RemotePluginMissingPluginId;

    try recordPluginShareLocalPath(allocator, codex_home, finalize_parse.value.plugin_id, plugin_path);
    return renderShareSaveJson(allocator, finalize_parse.value.plugin_id, finalize_parse.value.share_url);
}

pub fn updateShareTargetsJson(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    credentials: auth.Credentials,
    plugin_id: []const u8,
    share_targets: []const std.json.Value,
) ![]const u8 {
    const url = try pluginShareTargetsUrl(allocator, base_url, plugin_id);
    defer allocator.free(url);

    const payload = try renderShareTargetsRequestJson(allocator, share_targets);
    defer allocator.free(payload);
    const body = try sendJsonBytesWithPayload(allocator, url, .PUT, credentials, payload);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(RemotePluginShareUpdateTargetsResponsePayload, allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return renderShareTargetsUpdateJson(allocator, parsed.value.principals);
}

pub fn deleteShare(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    credentials: auth.Credentials,
    codex_home: []const u8,
    plugin_id: []const u8,
) !void {
    const url = try deletePluginShareUrl(allocator, base_url, plugin_id);
    defer allocator.free(url);
    const body = try sendJsonBytes(allocator, url, .DELETE, credentials);
    defer allocator.free(body);
    try removePluginShareLocalPath(allocator, codex_home, plugin_id);
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
    return sendJsonBytes(allocator, url, .GET, credentials);
}

fn fetchBytes(allocator: std.mem.Allocator, url: []const u8, max_bytes: usize) ![]const u8 {
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "User-Agent", .value = "codex-zig-port/0.0.1" });

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
    if (response_body.writer.end > max_bytes) return error.RemotePluginArchiveTooLarge;
    return response_body.toOwnedSlice();
}

fn sendJsonBytes(allocator: std.mem.Allocator, url: []const u8, method: std.http.Method, credentials: auth.Credentials) ![]const u8 {
    return sendJsonBytesWithPayload(allocator, url, method, credentials, null);
}

fn sendJsonBytesWithPayload(
    allocator: std.mem.Allocator,
    url: []const u8,
    method: std.http.Method,
    credentials: auth.Credentials,
    payload: ?[]const u8,
) ![]const u8 {
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    const auth_header = try auth.authorizationHeader(allocator, credentials);
    defer allocator.free(auth_header);
    try headers.append(allocator, .{ .name = "Authorization", .value = auth_header });
    try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "User-Agent", .value = "codex-zig-port/0.0.1" });
    if (payload != null) {
        try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
    }
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
        .method = method,
        .payload = payload orelse if (method.requestHasBody()) "" else null,
        .response_writer = &response_body.writer,
        .extra_headers = headers.items,
    });
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return error.RemotePluginHttpStatus;
    }

    return response_body.toOwnedSlice();
}

fn putWorkspacePluginUpload(allocator: std.mem.Allocator, url: []const u8, payload: []const u8) !void {
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "x-ms-blob-type", .value = "BlockBlob" });
    try headers.append(allocator, .{ .name = "Content-Type", .value = "application/gzip" });
    try headers.append(allocator, .{ .name = "User-Agent", .value = "codex-zig-port/0.0.1" });

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io_instance.io() };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .PUT,
        .payload = payload,
        .response_writer = &response_body.writer,
        .extra_headers = headers.items,
    });
    if (result.status != .ok and result.status != .created) {
        return error.RemotePluginHttpStatus;
    }
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

        var parsed = try std.json.parseFromSlice(RemotePluginListResponsePayload, allocator, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        var appended = false;
        errdefer if (!appended) parsed.deinit();
        next_page_token = parsed.value.pagination.next_page_token;
        try pages.append(allocator, parsed);
        appended = true;
        if (next_page_token == null) break;
    }

    return pages;
}

fn fetchCreatedWorkspacePluginPages(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    credentials: auth.Credentials,
) !RemotePluginListPages {
    var pages = RemotePluginListPages.empty;
    errdefer deinitPluginListPages(allocator, &pages);

    var next_page_token: ?[]const u8 = null;
    while (true) {
        const url = try createdWorkspacePluginsUrl(allocator, base_url, next_page_token);
        defer allocator.free(url);
        const body = try fetchJsonBytes(allocator, url, credentials);
        defer allocator.free(body);

        var parsed = try std.json.parseFromSlice(RemotePluginListResponsePayload, allocator, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
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

        var parsed = try std.json.parseFromSlice(RemotePluginInstalledResponsePayload, allocator, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
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

fn pluginDetailWithDownloadUrlsUrl(allocator: std.mem.Allocator, base_url: []const u8, plugin_id: []const u8) ![]const u8 {
    const detail_url = try pluginDetailUrl(allocator, base_url, plugin_id);
    defer allocator.free(detail_url);
    return std.fmt.allocPrint(allocator, "{s}?includeDownloadUrls=true", .{detail_url});
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

fn createdWorkspacePluginsUrl(allocator: std.mem.Allocator, base_url: []const u8, page_token: ?[]const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (trimmed.len == 0) return error.InvalidRemotePluginBaseUrl;

    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);
    try url.appendSlice(allocator, trimmed);
    try url.appendSlice(allocator, "/ps/plugins/workspace/created?limit=200");
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

fn uninstallPluginUrl(allocator: std.mem.Allocator, base_url: []const u8, plugin_id: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (trimmed.len == 0) return error.InvalidRemotePluginBaseUrl;

    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);
    try url.appendSlice(allocator, trimmed);
    try url.appendSlice(allocator, "/plugins/");
    try appendPathSegment(allocator, &url, plugin_id);
    try url.appendSlice(allocator, "/uninstall");
    return url.toOwnedSlice(allocator);
}

fn installPluginUrl(allocator: std.mem.Allocator, base_url: []const u8, plugin_id: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (trimmed.len == 0) return error.InvalidRemotePluginBaseUrl;

    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);
    try url.appendSlice(allocator, trimmed);
    try url.appendSlice(allocator, "/ps/plugins/");
    try appendPathSegment(allocator, &url, plugin_id);
    try url.appendSlice(allocator, "/install");
    return url.toOwnedSlice(allocator);
}

fn workspacePluginUploadUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (trimmed.len == 0) return error.InvalidRemotePluginBaseUrl;

    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);
    try url.appendSlice(allocator, trimmed);
    try url.appendSlice(allocator, "/public/plugins/workspace/upload-url");
    return url.toOwnedSlice(allocator);
}

fn workspacePluginFinalizeUrl(allocator: std.mem.Allocator, base_url: []const u8, plugin_id: ?[]const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (trimmed.len == 0) return error.InvalidRemotePluginBaseUrl;

    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);
    try url.appendSlice(allocator, trimmed);
    try url.appendSlice(allocator, "/public/plugins/workspace");
    if (plugin_id) |id| {
        try url.appendSlice(allocator, "/");
        try appendPathSegment(allocator, &url, id);
    }
    return url.toOwnedSlice(allocator);
}

fn pluginShareTargetsUrl(allocator: std.mem.Allocator, base_url: []const u8, plugin_id: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (trimmed.len == 0) return error.InvalidRemotePluginBaseUrl;

    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);
    try url.appendSlice(allocator, trimmed);
    try url.appendSlice(allocator, "/public/plugins/");
    try appendPathSegment(allocator, &url, plugin_id);
    try url.appendSlice(allocator, "/shares");
    return url.toOwnedSlice(allocator);
}

fn deletePluginShareUrl(allocator: std.mem.Allocator, base_url: []const u8, plugin_id: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (trimmed.len == 0) return error.InvalidRemotePluginBaseUrl;

    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);
    try url.appendSlice(allocator, trimmed);
    try url.appendSlice(allocator, "/public/plugins/workspace/");
    try appendPathSegment(allocator, &url, plugin_id);
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

fn renderShareListJson(
    allocator: std.mem.Allocator,
    created_pages: *const RemotePluginListPages,
    installed_pages: *const RemoteInstalledPluginPages,
    local_paths: PluginShareLocalPaths,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"data\":[");

    var count: usize = 0;
    for (created_pages.items) |page| {
        if (page.value.plugins) |plugins| {
            for (plugins) |plugin| {
                try appendCommaIfNeeded(allocator, &out, &count);
                try out.appendSlice(allocator, "{\"plugin\":");
                try appendRemotePluginSummaryJson(allocator, &out, plugin, .workspace, findInstalledPluginInPages(installed_pages, plugin.id));
                try out.appendSlice(allocator, ",\"shareUrl\":");
                try appendJsonString(allocator, &out, plugin.share_url orelse "");
                try out.appendSlice(allocator, ",\"localPluginPath\":");
                try appendOptionalStringJson(allocator, &out, local_paths.get(plugin.id));
                try out.appendSlice(allocator, "}");
            }
        }
    }

    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn renderShareSaveJson(allocator: std.mem.Allocator, remote_plugin_id: []const u8, share_url: ?[]const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"remotePluginId\":");
    try appendJsonString(allocator, &out, remote_plugin_id);
    try out.appendSlice(allocator, ",\"shareUrl\":");
    try appendJsonString(allocator, &out, share_url orelse "");
    try out.appendSlice(allocator, "}");
    return out.toOwnedSlice(allocator);
}

fn renderWorkspacePluginUploadUrlRequestJson(
    allocator: std.mem.Allocator,
    filename: []const u8,
    size_bytes: usize,
    plugin_id: ?[]const u8,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"filename\":");
    try appendJsonString(allocator, &out, filename);
    try out.appendSlice(allocator, ",\"mime_type\":\"application/gzip\",\"size_bytes\":");
    try out.print(allocator, "{d}", .{size_bytes});
    if (plugin_id) |id| {
        try out.appendSlice(allocator, ",\"plugin_id\":");
        try appendJsonString(allocator, &out, id);
    }
    try out.appendSlice(allocator, "}");
    return out.toOwnedSlice(allocator);
}

fn renderWorkspacePluginCreateRequestJson(
    allocator: std.mem.Allocator,
    file_id: []const u8,
    etag: []const u8,
    discoverability: ?[]const u8,
    share_targets: ?[]const std.json.Value,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"file_id\":");
    try appendJsonString(allocator, &out, file_id);
    try out.appendSlice(allocator, ",\"etag\":");
    try appendJsonString(allocator, &out, etag);
    if (discoverability) |value| {
        try out.appendSlice(allocator, ",\"discoverability\":");
        try appendJsonString(allocator, &out, value);
    }
    if (share_targets) |targets| {
        try out.appendSlice(allocator, ",\"share_targets\":");
        try appendShareTargetsArraySnakeCase(allocator, &out, targets);
    }
    try out.appendSlice(allocator, "}");
    return out.toOwnedSlice(allocator);
}

fn renderShareTargetsRequestJson(allocator: std.mem.Allocator, share_targets: []const std.json.Value) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"targets\":[");
    try appendShareTargetsArrayBodySnakeCase(allocator, &out, share_targets);
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn appendShareTargetsArraySnakeCase(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    share_targets: []const std.json.Value,
) !void {
    try out.appendSlice(allocator, "[");
    try appendShareTargetsArrayBodySnakeCase(allocator, out, share_targets);
    try out.appendSlice(allocator, "]");
}

fn appendShareTargetsArrayBodySnakeCase(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    share_targets: []const std.json.Value,
) !void {
    for (share_targets, 0..) |target, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try appendShareTargetSnakeCase(allocator, out, target);
    }
}

fn appendShareTargetSnakeCase(allocator: std.mem.Allocator, out: *std.ArrayList(u8), target: std.json.Value) !void {
    const object = target.object;
    try out.appendSlice(allocator, "{\"principal_type\":");
    try appendJsonString(allocator, out, object.get("principalType").?.string);
    try out.appendSlice(allocator, ",\"principal_id\":");
    try appendJsonString(allocator, out, object.get("principalId").?.string);
    try out.appendSlice(allocator, "}");
}

fn renderShareTargetsUpdateJson(allocator: std.mem.Allocator, principals: []const RemotePluginSharePrincipalPayload) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"principals\":[");
    for (principals, 0..) |principal, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try appendRemoteSharePrincipalJson(allocator, &out, principal);
    }
    try out.appendSlice(allocator, "]}");
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
        try appendRemoteSharePrincipalJson(allocator, out, principal);
    }
    try out.appendSlice(allocator, "]");
}

fn appendRemoteSharePrincipalJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    principal: RemotePluginSharePrincipalPayload,
) !void {
    try out.appendSlice(allocator, "{\"principalType\":");
    try appendJsonString(allocator, out, principal.principal_type);
    try out.appendSlice(allocator, ",\"principalId\":");
    try appendJsonString(allocator, out, principal.principal_id);
    try out.appendSlice(allocator, ",\"name\":");
    try appendJsonString(allocator, out, principal.name);
    try out.appendSlice(allocator, "}");
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

fn removeRemotePluginCache(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    marketplace_name_value: []const u8,
    plugin_name: []const u8,
    legacy_plugin_id: []const u8,
) !void {
    if (!isSafePluginCacheSegment(marketplace_name_value) or
        !isSafePluginCacheSegment(plugin_name) or
        !isSafeCachePathSegment(legacy_plugin_id))
    {
        return error.RemotePluginInvalidCachePath;
    }

    const plugin_cache_root = try std.fs.path.join(allocator, &.{ codex_home, "plugins", "cache", marketplace_name_value, plugin_name });
    defer allocator.free(plugin_cache_root);
    try deleteCachePathIfPresent(plugin_cache_root);

    const legacy_cache_root = try std.fs.path.join(allocator, &.{ codex_home, "plugins", "cache", marketplace_name_value, legacy_plugin_id });
    defer allocator.free(legacy_cache_root);
    if (!std.mem.eql(u8, legacy_cache_root, plugin_cache_root)) {
        try deleteCachePathIfPresent(legacy_cache_root);
    }
}

fn deleteCachePathIfPresent(path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    std.Io.Dir.cwd().deleteTree(io, path) catch |err| return err;
}

fn isSafeCachePathSegment(value: []const u8) bool {
    if (value.len == 0 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') continue;
        return false;
    }
    return true;
}

fn isSafePluginCacheSegment(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') continue;
        return false;
    }
    return true;
}

fn isSafePluginVersionSegment(value: []const u8) bool {
    if (value.len == 0 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '+') continue;
        return false;
    }
    return true;
}

const PluginShareLocalPaths = struct {
    parsed: ?std.json.Parsed(std.json.Value) = null,

    fn deinit(self: *PluginShareLocalPaths) void {
        if (self.parsed) |*parsed| parsed.deinit();
    }

    fn get(self: PluginShareLocalPaths, remote_plugin_id: []const u8) ?[]const u8 {
        const parsed = self.parsed orelse return null;
        if (parsed.value != .object) return null;
        const mapping = parsed.value.object.get("localPluginPathsByRemotePluginId") orelse return null;
        if (mapping != .object) return null;
        const value = mapping.object.get(remote_plugin_id) orelse return null;
        if (value != .string or value.string.len == 0) return null;
        return value.string;
    }
};

fn loadPluginShareLocalPaths(allocator: std.mem.Allocator, codex_home: []const u8) !PluginShareLocalPaths {
    const path = try pluginShareLocalPathsPath(allocator, codex_home);
    defer allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always }) catch return .{};
    return .{ .parsed = parsed };
}

fn recordPluginShareLocalPath(allocator: std.mem.Allocator, codex_home: []const u8, remote_plugin_id: []const u8, plugin_path: []const u8) !void {
    var local_paths = try loadPluginShareLocalPaths(allocator, codex_home);
    defer local_paths.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"localPluginPathsByRemotePluginId\":{");
    var count: usize = 0;
    var replaced = false;
    if (local_paths.parsed) |parsed| {
        if (parsed.value == .object) {
            if (parsed.value.object.get("localPluginPathsByRemotePluginId")) |mapping| {
                if (mapping == .object) {
                    var iter = mapping.object.iterator();
                    while (iter.next()) |entry| {
                        if (entry.value_ptr.* != .string) continue;
                        try appendCommaIfNeeded(allocator, &out, &count);
                        try appendJsonString(allocator, &out, entry.key_ptr.*);
                        try out.appendSlice(allocator, ":");
                        if (std.mem.eql(u8, entry.key_ptr.*, remote_plugin_id)) {
                            try appendJsonString(allocator, &out, plugin_path);
                            replaced = true;
                        } else {
                            try appendJsonString(allocator, &out, entry.value_ptr.*.string);
                        }
                    }
                }
            }
        }
    }
    if (!replaced) {
        try appendCommaIfNeeded(allocator, &out, &count);
        try appendJsonString(allocator, &out, remote_plugin_id);
        try out.appendSlice(allocator, ":");
        try appendJsonString(allocator, &out, plugin_path);
    }
    try out.appendSlice(allocator, "}}\n");

    const path = try pluginShareLocalPathsPath(allocator, codex_home);
    defer allocator.free(path);
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPluginShareLocalPathsPath;
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), parent);
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = out.items });
}

fn removePluginShareLocalPath(allocator: std.mem.Allocator, codex_home: []const u8, remote_plugin_id: []const u8) !void {
    var local_paths = try loadPluginShareLocalPaths(allocator, codex_home);
    defer local_paths.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"localPluginPathsByRemotePluginId\":{");
    var count: usize = 0;
    if (local_paths.parsed) |parsed| {
        if (parsed.value == .object) {
            if (parsed.value.object.get("localPluginPathsByRemotePluginId")) |mapping| {
                if (mapping == .object) {
                    var iter = mapping.object.iterator();
                    while (iter.next()) |entry| {
                        if (std.mem.eql(u8, entry.key_ptr.*, remote_plugin_id)) continue;
                        if (entry.value_ptr.* != .string) continue;
                        try appendCommaIfNeeded(allocator, &out, &count);
                        try appendJsonString(allocator, &out, entry.key_ptr.*);
                        try out.appendSlice(allocator, ":");
                        try appendJsonString(allocator, &out, entry.value_ptr.*.string);
                    }
                }
            }
        }
    }
    try out.appendSlice(allocator, "}}\n");

    const path = try pluginShareLocalPathsPath(allocator, codex_home);
    defer allocator.free(path);
    if (count == 0) {
        std.Io.Dir.deleteFileAbsolute(std.Io.Threaded.global_single_threaded.io(), path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        return;
    }
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPluginShareLocalPathsPath;
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), parent);
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = out.items });
}

fn pluginShareLocalPathsPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ codex_home, ".tmp", "plugin-share-local-paths-v1.json" });
}

fn archiveFilename(allocator: std.mem.Allocator, plugin_path: []const u8) ![]const u8 {
    const plugin_name = std.fs.path.basename(plugin_path);
    if (plugin_name.len == 0 or std.mem.eql(u8, plugin_name, ".") or std.mem.eql(u8, plugin_name, "..")) {
        return error.RemotePluginInvalidPluginPath;
    }
    return std.fmt.allocPrint(allocator, "{s}.tar.gz", .{plugin_name});
}

fn archivePluginForUpload(allocator: std.mem.Allocator, plugin_path: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const plugin_metadata = std.Io.Dir.cwd().statFile(io, plugin_path, .{}) catch return error.RemotePluginInvalidPluginPath;
    if (plugin_metadata.kind != .directory) return error.RemotePluginInvalidPluginPath;

    const manifest_path = try std.fs.path.join(allocator, &.{ plugin_path, ".codex-plugin", "plugin.json" });
    defer allocator.free(manifest_path);
    const manifest_metadata = std.Io.Dir.cwd().statFile(io, manifest_path, .{}) catch return error.RemotePluginInvalidPluginPath;
    if (manifest_metadata.kind != .file) return error.RemotePluginInvalidPluginPath;

    var tar_out: std.Io.Writer.Allocating = .init(allocator);
    defer tar_out.deinit();
    var tar_writer = std.tar.Writer{ .underlying_writer = &tar_out.writer };
    try appendPluginTreeToTar(allocator, &tar_writer, plugin_path, "");
    try tar_writer.finishPedantically();
    const tar_bytes = try tar_out.toOwnedSlice();
    defer allocator.free(tar_bytes);

    return gzipCompressed(allocator, tar_bytes, REMOTE_PLUGIN_SHARE_MAX_ARCHIVE_BYTES);
}

fn appendPluginTreeToTar(
    allocator: std.mem.Allocator,
    tar_writer: *std.tar.Writer,
    current_path: []const u8,
    relative_prefix: []const u8,
) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.openDirAbsolute(io, current_path, .{ .iterate = true });
    defer dir.close(io);

    var entries = std.ArrayList(ArchiveTreeEntry).empty;
    defer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .kind = entry.kind,
        });
    }
    std.mem.sort(ArchiveTreeEntry, entries.items, {}, archiveTreeEntryLessThan);

    for (entries.items) |entry| {
        const name = entry.name;
        const full_path = try std.fs.path.join(allocator, &.{ current_path, name });
        defer allocator.free(full_path);
        const rel_path = if (relative_prefix.len == 0)
            try allocator.dupe(u8, name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_prefix, name });
        defer allocator.free(rel_path);

        if (entry.kind == .directory) {
            try tar_writer.writeDir(rel_path, .{ .mode = 0o755, .mtime = 0 });
            try appendPluginTreeToTar(allocator, tar_writer, full_path, rel_path);
        } else if (entry.kind == .file) {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .limited(REMOTE_PLUGIN_SHARE_MAX_ARCHIVE_BYTES + 1));
            defer allocator.free(bytes);
            try tar_writer.writeFileBytes(rel_path, bytes, .{ .mode = 0o644, .mtime = 0 });
        } else {
            return error.RemotePluginUnsupportedArchiveEntry;
        }
    }
}

fn archiveTreeEntryLessThan(_: void, lhs: ArchiveTreeEntry, rhs: ArchiveTreeEntry) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

fn gzipCompressed(allocator: std.mem.Allocator, payload: []const u8, max_bytes: usize) ![]const u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(allocator, @min(payload.len + 18, max_bytes + 1));
    errdefer out.deinit();

    var compressor_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&out.writer, &compressor_buffer, .gzip, .default);
    try compressor.writer.writeAll(payload);
    try compressor.finish();

    if (out.writer.end > max_bytes) return error.RemotePluginArchiveTooLarge;
    return out.toOwnedSlice();
}

fn installRemotePluginBundle(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    marketplace_name_value: []const u8,
    plugin_name: []const u8,
    plugin_version: []const u8,
    archive: []const u8,
) ![]const u8 {
    if (!isSafePluginCacheSegment(marketplace_name_value) or
        !isSafePluginCacheSegment(plugin_name) or
        !isSafePluginVersionSegment(plugin_version))
    {
        return error.RemotePluginInvalidCachePath;
    }

    const plugin_base_root = try std.fs.path.join(allocator, &.{ codex_home, "plugins", "cache", marketplace_name_value, plugin_name });
    defer allocator.free(plugin_base_root);
    const installed_path = try std.fs.path.join(allocator, &.{ plugin_base_root, plugin_version });
    errdefer allocator.free(installed_path);

    const extract_root = try std.fmt.allocPrint(allocator, "{s}.download", .{plugin_base_root});
    defer allocator.free(extract_root);
    const staged_base_root = try std.fmt.allocPrint(allocator, "{s}.installing", .{plugin_base_root});
    defer allocator.free(staged_base_root);
    const backup_base_root = try std.fmt.allocPrint(allocator, "{s}.previous", .{plugin_base_root});
    defer allocator.free(backup_base_root);
    const staged_installed_path = try std.fs.path.join(allocator, &.{ staged_base_root, plugin_version });
    defer allocator.free(staged_installed_path);

    try deleteCachePathIfPresent(extract_root);
    try deleteCachePathIfPresent(staged_base_root);
    try deleteCachePathIfPresent(backup_base_root);
    errdefer deleteCachePathIfPresent(extract_root) catch {};
    errdefer deleteCachePathIfPresent(staged_base_root) catch {};

    try extractRemotePluginArchive(allocator, archive, extract_root);
    const extracted_plugin_root = try findExtractedPluginRoot(allocator, extract_root, plugin_name, plugin_version);
    defer allocator.free(extracted_plugin_root);
    try copyDirRecursive(allocator, extracted_plugin_root, staged_installed_path);

    const had_existing = try renamePathIfPresent(plugin_base_root, backup_base_root);
    std.Io.Dir.renameAbsolute(staged_base_root, plugin_base_root, std.Io.Threaded.global_single_threaded.io()) catch |err| {
        if (had_existing) {
            std.Io.Dir.renameAbsolute(backup_base_root, plugin_base_root, std.Io.Threaded.global_single_threaded.io()) catch {};
        }
        return err;
    };
    if (had_existing) deleteCachePathIfPresent(backup_base_root) catch {};
    try deleteCachePathIfPresent(extract_root);
    return installed_path;
}

fn extractRemotePluginArchive(allocator: std.mem.Allocator, archive: []const u8, extract_root: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, extract_root);

    var gzip_reader: std.Io.Reader = .fixed(archive);
    var tar_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer tar_bytes.deinit();
    var decompressor: std.compress.flate.Decompress = .init(&gzip_reader, .gzip, &.{});
    _ = try decompressor.reader.streamRemaining(&tar_bytes.writer);
    if (tar_bytes.writer.end > REMOTE_PLUGIN_SHARE_MAX_ARCHIVE_BYTES) return error.RemotePluginArchiveTooLarge;

    var tar_reader: std.Io.Reader = .fixed(tar_bytes.written());
    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var iter = std.tar.Iterator.init(&tar_reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });

    var clean_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    while (try iter.next()) |file| {
        const clean_path = try sanitizeRemoteArchivePath(&clean_path_buffer, file.name);
        if (file.kind == .sym_link) return error.RemotePluginUnsupportedArchiveEntry;
        if (clean_path.len == 0) {
            if (file.kind == .directory) continue;
            return error.RemotePluginInvalidArchivePath;
        }

        const output_path = try std.fs.path.join(allocator, &.{ extract_root, clean_path });
        defer allocator.free(output_path);

        switch (file.kind) {
            .directory => try std.Io.Dir.cwd().createDirPath(io, output_path),
            .file => {
                if (std.fs.path.dirname(output_path)) |parent| {
                    try std.Io.Dir.cwd().createDirPath(io, parent);
                }
                var out_file = try std.Io.Dir.cwd().createFile(io, output_path, .{ .exclusive = true });
                defer out_file.close(io);
                var write_buffer: [8192]u8 = undefined;
                var writer = out_file.writer(io, &write_buffer);
                try iter.streamRemaining(file, &writer.interface);
                try writer.interface.flush();
            },
            .sym_link => unreachable,
        }
    }
}

fn sanitizeRemoteArchivePath(buffer: []u8, path: []const u8) ![]const u8 {
    if (path.len == 0 or path[0] == '/') return error.RemotePluginInvalidArchivePath;
    var output_len: usize = 0;
    var components = std.mem.tokenizeScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) return error.RemotePluginInvalidArchivePath;
        if (std.mem.indexOfScalar(u8, component, 0) != null) return error.RemotePluginInvalidArchivePath;
        if (output_len > 0) {
            if (output_len >= buffer.len) return error.RemotePluginInvalidArchivePath;
            buffer[output_len] = '/';
            output_len += 1;
        }
        if (output_len + component.len > buffer.len) return error.RemotePluginInvalidArchivePath;
        @memcpy(buffer[output_len..][0..component.len], component);
        output_len += component.len;
    }
    return buffer[0..output_len];
}

fn findExtractedPluginRoot(
    allocator: std.mem.Allocator,
    extract_root: []const u8,
    expected_name: []const u8,
    expected_version: []const u8,
) ![]const u8 {
    if (try isValidExtractedPluginRoot(allocator, extract_root, expected_name, expected_version)) {
        return allocator.dupe(u8, extract_root);
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.openDirAbsolute(io, extract_root, .{ .iterate = true });
    defer dir.close(io);

    var found_root: ?[]const u8 = null;
    errdefer if (found_root) |root| allocator.free(root);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const candidate = try std.fs.path.join(allocator, &.{ extract_root, entry.name });
        errdefer allocator.free(candidate);
        if (try isValidExtractedPluginRoot(allocator, candidate, expected_name, expected_version)) {
            if (found_root != null) {
                allocator.free(candidate);
                return error.RemotePluginAmbiguousBundleRoot;
            }
            found_root = candidate;
        } else {
            allocator.free(candidate);
        }
    }

    return found_root orelse error.RemotePluginMissingBundleManifest;
}

fn isValidExtractedPluginRoot(
    allocator: std.mem.Allocator,
    plugin_root: []const u8,
    expected_name: []const u8,
    expected_version: []const u8,
) !bool {
    const manifest_path = try std.fs.path.join(allocator, &.{ plugin_root, ".codex-plugin", "plugin.json" });
    defer allocator.free(manifest_path);
    const manifest_bytes = std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        manifest_path,
        allocator,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(manifest_bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, manifest_bytes, .{}) catch return error.RemotePluginInvalidBundleManifest;
    defer parsed.deinit();
    if (parsed.value != .object) return error.RemotePluginInvalidBundleManifest;
    const object = parsed.value.object;
    const name = object.get("name") orelse return error.RemotePluginInvalidBundleManifest;
    if (name != .string or !std.mem.eql(u8, name.string, expected_name)) {
        return error.RemotePluginBundleNameMismatch;
    }
    const version = object.get("version") orelse return error.RemotePluginBundleVersionMismatch;
    if (version != .string or !std.mem.eql(u8, version.string, expected_version)) {
        return error.RemotePluginBundleVersionMismatch;
    }
    return true;
}

fn copyDirRecursive(allocator: std.mem.Allocator, source_root: []const u8, target_root: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, target_root);

    var source_dir = try std.Io.Dir.openDirAbsolute(io, source_root, .{ .iterate = true });
    defer source_dir.close(io);

    var iter = source_dir.iterate();
    while (try iter.next(io)) |entry| {
        const source_path = try std.fs.path.join(allocator, &.{ source_root, entry.name });
        defer allocator.free(source_path);
        const target_path = try std.fs.path.join(allocator, &.{ target_root, entry.name });
        defer allocator.free(target_path);

        if (entry.kind == .directory) {
            try copyDirRecursive(allocator, source_path, target_path);
        } else if (entry.kind == .file) {
            try std.Io.Dir.copyFileAbsolute(source_path, target_path, io, .{});
        } else {
            return error.RemotePluginUnsupportedArchiveEntry;
        }
    }
}

fn renamePathIfPresent(old_path: []const u8, new_path: []const u8) !bool {
    std.Io.Dir.renameAbsolute(old_path, new_path, std.Io.Threaded.global_single_threaded.io()) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn renderInstallResponseJson(allocator: std.mem.Allocator, auth_policy: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"authPolicy\":");
    try appendJsonString(allocator, &out, auth_policy);
    try out.appendSlice(allocator, ",\"appsNeedingAuth\":[]}");
    return out.toOwnedSlice(allocator);
}

fn isRemoteBundleDownloadUrlAllowed(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "https://")) return true;
    if (!std.mem.startsWith(u8, url, "http://")) return false;
    if (std.c.getenv("CODEX_TEST_ALLOW_HTTP_REMOTE_PLUGIN_BUNDLE_DOWNLOADS") == null) return false;

    const authority_start = "http://".len;
    const rest = url[authority_start..];
    const authority_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..authority_end];
    if (std.mem.eql(u8, authority, "[::1]")) return true;
    if (std.mem.startsWith(u8, authority, "[::1]:")) return true;

    const colon_index = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
    const host = authority[0..colon_index];
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost");
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

    const detail_with_downloads_url = try pluginDetailWithDownloadUrlsUrl(allocator, "https://chatgpt.com/backend-api/", "plugins~Plugin_123");
    defer allocator.free(detail_with_downloads_url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/ps/plugins/plugins~Plugin_123?includeDownloadUrls=true", detail_with_downloads_url);

    const install_url = try installPluginUrl(allocator, "https://chatgpt.com/backend-api/", "plugins~Plugin_123");
    defer allocator.free(install_url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/ps/plugins/plugins~Plugin_123/install", install_url);

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

test "remote plugin marketplace JSON renders directory and installed state" {
    const allocator = std.testing.allocator;
    const list_body =
        \\{
        \\  "plugins": [
        \\    {
        \\      "id": "plugins~Plugin_123",
        \\      "name": "linear",
        \\      "scope": "GLOBAL",
        \\      "installation_policy": "AVAILABLE",
        \\      "authentication_policy": "ON_USE",
        \\      "status": "ENABLED",
        \\      "release": {
        \\        "display_name": "Linear",
        \\        "description": "Track work in Linear",
        \\        "app_ids": ["gmail"],
        \\        "keywords": ["issue-tracking"],
        \\        "interface": {"short_description": "Plan and track work"},
        \\        "skills": []
        \\      }
        \\    }
        \\  ],
        \\  "pagination": {"limit": 200, "next_page_token": null}
        \\}
    ;
    const installed_body =
        \\{
        \\  "plugins": [
        \\    {
        \\      "id": "plugins~Plugin_123",
        \\      "name": "linear",
        \\      "scope": "GLOBAL",
        \\      "installation_policy": "AVAILABLE",
        \\      "authentication_policy": "ON_USE",
        \\      "release": {
        \\        "display_name": "Linear",
        \\        "description": "Track work in Linear",
        \\        "app_ids": [],
        \\        "keywords": [],
        \\        "interface": {},
        \\        "skills": []
        \\      },
        \\      "enabled": false,
        \\      "disabled_skill_names": []
        \\    }
        \\  ],
        \\  "pagination": {"limit": 50, "next_page_token": null}
        \\}
    ;

    var directory_pages = RemotePluginListPages.empty;
    defer deinitPluginListPages(allocator, &directory_pages);
    const list_parse = try std.json.parseFromSlice(RemotePluginListResponsePayload, allocator, list_body, .{ .ignore_unknown_fields = true });
    try directory_pages.append(allocator, list_parse);

    var installed_pages = RemoteInstalledPluginPages.empty;
    defer deinitInstalledPluginPages(allocator, &installed_pages);
    const installed_parse = try std.json.parseFromSlice(RemotePluginInstalledResponsePayload, allocator, installed_body, .{ .ignore_unknown_fields = true });
    try installed_pages.append(allocator, installed_parse);

    var rendered = std.ArrayList(u8).empty;
    defer rendered.deinit(allocator);
    try rendered.appendSlice(allocator, "[");
    var marketplace_count: usize = 0;
    try appendRemoteMarketplaceJsonFromPages(
        allocator,
        &rendered,
        &marketplace_count,
        "chatgpt-global",
        "ChatGPT Plugins",
        .global,
        &directory_pages,
        &installed_pages,
        true,
    );
    try rendered.appendSlice(allocator, "]");

    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "\"name\":\"chatgpt-global\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "\"installed\":true,\"enabled\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "\"keywords\":[\"issue-tracking\"]") != null);
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

test "remote share list JSON includes local path mappings" {
    const allocator = std.testing.allocator;
    const created_body =
        \\{
        \\  "plugins": [
        \\    {
        \\      "id": "plugins~Plugin_456",
        \\      "name": "shared-linear",
        \\      "scope": "WORKSPACE",
        \\      "share_url": "https://chatgpt.example/share",
        \\      "installation_policy": "AVAILABLE",
        \\      "authentication_policy": "ON_USE",
        \\      "release": {
        \\        "display_name": "Shared Linear",
        \\        "description": "",
        \\        "app_ids": [],
        \\        "keywords": [],
        \\        "interface": {},
        \\        "skills": []
        \\      }
        \\    }
        \\  ],
        \\  "pagination": {"next_page_token": null}
        \\}
    ;
    const installed_body =
        \\{
        \\  "plugins": [
        \\    {
        \\      "id": "plugins~Plugin_456",
        \\      "name": "shared-linear",
        \\      "scope": "WORKSPACE",
        \\      "installation_policy": "AVAILABLE",
        \\      "authentication_policy": "ON_USE",
        \\      "release": {
        \\        "display_name": "Shared Linear",
        \\        "description": "",
        \\        "app_ids": [],
        \\        "keywords": [],
        \\        "interface": {},
        \\        "skills": []
        \\      },
        \\      "enabled": true
        \\    }
        \\  ],
        \\  "pagination": {"next_page_token": null}
        \\}
    ;
    const local_paths_body =
        \\{"localPluginPathsByRemotePluginId":{"plugins~Plugin_456":"/tmp/shared-linear"}}
    ;

    var created_pages = RemotePluginListPages.empty;
    defer deinitPluginListPages(allocator, &created_pages);
    const created_parse = try std.json.parseFromSlice(RemotePluginListResponsePayload, allocator, created_body, .{ .ignore_unknown_fields = true });
    try created_pages.append(allocator, created_parse);

    var installed_pages = RemoteInstalledPluginPages.empty;
    defer deinitInstalledPluginPages(allocator, &installed_pages);
    const installed_parse = try std.json.parseFromSlice(RemotePluginInstalledResponsePayload, allocator, installed_body, .{ .ignore_unknown_fields = true });
    try installed_pages.append(allocator, installed_parse);

    const local_paths_parse = try std.json.parseFromSlice(std.json.Value, allocator, local_paths_body, .{ .allocate = .alloc_always });
    var local_paths = PluginShareLocalPaths{ .parsed = local_paths_parse };
    defer local_paths.deinit();

    const rendered = try renderShareListJson(allocator, &created_pages, &installed_pages, local_paths);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"data\":[{\"plugin\":{\"id\":\"plugins~Plugin_456\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"installed\":true,\"enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"shareUrl\":\"https://chatgpt.example/share\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"localPluginPath\":\"/tmp/shared-linear\"") != null);
}

test "remote share target request and response JSON use Rust wire casing" {
    const allocator = std.testing.allocator;
    var request_parse = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"shareTargets":[{"principalType":"user","principalId":"user-1"},{"principalType":"workspace","principalId":"workspace-1"}]}
    , .{});
    defer request_parse.deinit();

    const request = try renderShareTargetsRequestJson(allocator, request_parse.value.object.get("shareTargets").?.array.items);
    defer allocator.free(request);
    try std.testing.expectEqualStrings(
        "{\"targets\":[{\"principal_type\":\"user\",\"principal_id\":\"user-1\"},{\"principal_type\":\"workspace\",\"principal_id\":\"workspace-1\"}]}",
        request,
    );

    const response_body =
        \\{"principals":[{"principal_type":"user","principal_id":"user-1","name":"Gavin"}]}
    ;
    var response_parse = try std.json.parseFromSlice(RemotePluginShareUpdateTargetsResponsePayload, allocator, response_body, .{ .ignore_unknown_fields = true });
    defer response_parse.deinit();
    const response = try renderShareTargetsUpdateJson(allocator, response_parse.value.principals);
    defer allocator.free(response);
    try std.testing.expectEqualStrings(
        "{\"principals\":[{\"principalType\":\"user\",\"principalId\":\"user-1\",\"name\":\"Gavin\"}]}",
        response,
    );
}

test "remote share save request JSON uses Rust workspace upload casing" {
    const allocator = std.testing.allocator;
    var request_parse = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"shareTargets":[{"principalType":"user","principalId":"user-1"},{"principalType":"workspace","principalId":"workspace-1"}]}
    , .{});
    defer request_parse.deinit();

    const upload_request = try renderWorkspacePluginUploadUrlRequestJson(allocator, "shared-plugin.tar.gz", 123, "plugins~Plugin_123");
    defer allocator.free(upload_request);
    try std.testing.expectEqualStrings(
        "{\"filename\":\"shared-plugin.tar.gz\",\"mime_type\":\"application/gzip\",\"size_bytes\":123,\"plugin_id\":\"plugins~Plugin_123\"}",
        upload_request,
    );

    const create_request = try renderWorkspacePluginCreateRequestJson(
        allocator,
        "file_123",
        "upload-etag",
        "PRIVATE",
        request_parse.value.object.get("shareTargets").?.array.items,
    );
    defer allocator.free(create_request);
    try std.testing.expectEqualStrings(
        "{\"file_id\":\"file_123\",\"etag\":\"upload-etag\",\"discoverability\":\"PRIVATE\",\"share_targets\":[{\"principal_type\":\"user\",\"principal_id\":\"user-1\"},{\"principal_type\":\"workspace\",\"principal_id\":\"workspace-1\"}]}",
        create_request,
    );

    const response = try renderShareSaveJson(allocator, "plugins~Plugin_456", "https://chatgpt.example/share");
    defer allocator.free(response);
    try std.testing.expectEqualStrings(
        "{\"remotePluginId\":\"plugins~Plugin_456\",\"shareUrl\":\"https://chatgpt.example/share\"}",
        response,
    );
}

test "remote share archive is gzip tar with plugin files" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try dir.dir.createDirPath(io, "shared/.codex-plugin");
    try dir.dir.createDirPath(io, "shared/skills/example");
    try dir.dir.writeFile(io, .{
        .sub_path = "shared/.codex-plugin/plugin.json",
        .data = "{\"name\":\"shared\"}",
    });
    try dir.dir.writeFile(io, .{
        .sub_path = "shared/skills/example/SKILL.md",
        .data = "# Example\n",
    });

    const plugin_path = try dir.dir.realPathFileAlloc(io, "shared", allocator);
    defer allocator.free(plugin_path);
    const archive = try archivePluginForUpload(allocator, plugin_path);
    defer allocator.free(archive);
    try std.testing.expect(archive.len > 10);
    try std.testing.expectEqual(@as(u8, 0x1f), archive[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), archive[1]);

    var gzip_reader: std.Io.Reader = .fixed(archive);
    var tar_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer tar_bytes.deinit();
    var decompressor: std.compress.flate.Decompress = .init(&gzip_reader, .gzip, &.{});
    _ = try decompressor.reader.streamRemaining(&tar_bytes.writer);

    var tar_reader: std.Io.Reader = .fixed(tar_bytes.written());
    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var iter = std.tar.Iterator.init(&tar_reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });

    var saw_manifest = false;
    var saw_skill = false;
    while (try iter.next()) |file| {
        if (file.kind != .file) continue;
        var body: std.Io.Writer.Allocating = .init(allocator);
        defer body.deinit();
        try iter.streamRemaining(file, &body.writer);
        if (std.mem.eql(u8, file.name, ".codex-plugin/plugin.json")) {
            saw_manifest = true;
            try std.testing.expectEqualStrings("{\"name\":\"shared\"}", body.written());
        } else if (std.mem.eql(u8, file.name, "skills/example/SKILL.md")) {
            saw_skill = true;
            try std.testing.expectEqualStrings("# Example\n", body.written());
        }
    }
    try std.testing.expect(saw_manifest);
    try std.testing.expect(saw_skill);
}

test "remote share archive rejects symlink entries" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try dir.dir.createDirPath(io, "shared/.codex-plugin");
    try dir.dir.writeFile(io, .{
        .sub_path = "shared/.codex-plugin/plugin.json",
        .data = "{\"name\":\"shared\"}",
    });
    try dir.dir.writeFile(io, .{
        .sub_path = "outside.txt",
        .data = "outside",
    });
    try dir.dir.symLink(io, "../outside.txt", "shared/leak.txt", .{});

    const plugin_path = try dir.dir.realPathFileAlloc(io, "shared", allocator);
    defer allocator.free(plugin_path);
    try std.testing.expectError(error.RemotePluginUnsupportedArchiveEntry, archivePluginForUpload(allocator, plugin_path));
}

test "remote install bundle writes versioned cache from root archive" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try dir.dir.createDirPath(io, "home");
    try dir.dir.createDirPath(io, "linear/.codex-plugin");
    try dir.dir.createDirPath(io, "linear/skills/plan-work");
    try dir.dir.writeFile(io, .{
        .sub_path = "linear/.codex-plugin/plugin.json",
        .data = "{\"name\":\"linear\",\"version\":\"1.2.3\"}",
    });
    try dir.dir.writeFile(io, .{
        .sub_path = "linear/skills/plan-work/SKILL.md",
        .data = "# Plan Work\n",
    });

    const plugin_path = try dir.dir.realPathFileAlloc(io, "linear", allocator);
    defer allocator.free(plugin_path);
    const archive = try archivePluginForUpload(allocator, plugin_path);
    defer allocator.free(archive);

    const codex_home = try dir.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(codex_home);
    const installed_path = try installRemotePluginBundle(allocator, codex_home, "chatgpt-global", "linear", "1.2.3", archive);
    defer allocator.free(installed_path);

    const expected_path = try std.fs.path.join(allocator, &.{ codex_home, "plugins", "cache", "chatgpt-global", "linear", "1.2.3" });
    defer allocator.free(expected_path);
    try std.testing.expectEqualStrings(expected_path, installed_path);
    try std.testing.expect((try std.Io.Dir.cwd().statFile(io, installed_path, .{})).kind == .directory);

    const manifest_path = try std.fs.path.join(allocator, &.{ installed_path, ".codex-plugin", "plugin.json" });
    defer allocator.free(manifest_path);
    const skill_path = try std.fs.path.join(allocator, &.{ installed_path, "skills", "plan-work", "SKILL.md" });
    defer allocator.free(skill_path);
    try std.testing.expect((try std.Io.Dir.cwd().statFile(io, manifest_path, .{})).kind == .file);
    try std.testing.expect((try std.Io.Dir.cwd().statFile(io, skill_path, .{})).kind == .file);

    const download_path = try std.fs.path.join(allocator, &.{ codex_home, "plugins", "cache", "chatgpt-global", "linear.download" });
    defer allocator.free(download_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, download_path, .{}));
}

test "remote install bundle rejects symlink entries" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try dir.dir.createDirPath(io, "home");

    var tar_out: std.Io.Writer.Allocating = .init(allocator);
    defer tar_out.deinit();
    var tar_writer = std.tar.Writer{ .underlying_writer = &tar_out.writer };
    try tar_writer.writeDir(".codex-plugin", .{ .mode = 0o755, .mtime = 0 });
    try tar_writer.writeFileBytes(".codex-plugin/plugin.json", "{\"name\":\"linear\",\"version\":\"1.2.3\"}", .{ .mode = 0o644, .mtime = 0 });
    try tar_writer.writeLink("skills/leak", "/tmp/leak", .{ .mode = 0o777, .mtime = 0 });
    try tar_writer.finishPedantically();
    const archive = try gzipCompressed(allocator, tar_out.written(), REMOTE_PLUGIN_SHARE_MAX_ARCHIVE_BYTES);
    defer allocator.free(archive);

    const codex_home = try dir.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(codex_home);
    try std.testing.expectError(
        error.RemotePluginUnsupportedArchiveEntry,
        installRemotePluginBundle(allocator, codex_home, "chatgpt-global", "linear", "1.2.3", archive),
    );
}

test "remote share local path removal preserves unrelated mappings" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try dir.dir.createDirPath(io, "home/.tmp");
    try dir.dir.writeFile(io, .{
        .sub_path = "home/.tmp/plugin-share-local-paths-v1.json",
        .data =
        \\{"localPluginPathsByRemotePluginId":{"plugins~Plugin_123":"/tmp/one","plugins~Plugin_456":"/tmp/two"}}
        ,
    });

    const root = try dir.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(root);
    try removePluginShareLocalPath(allocator, root, "plugins~Plugin_123");

    const mapping_path = try pluginShareLocalPathsPath(allocator, root);
    defer allocator.free(mapping_path);
    const remaining = try std.Io.Dir.cwd().readFileAlloc(io, mapping_path, allocator, .limited(1024));
    defer allocator.free(remaining);
    try std.testing.expect(std.mem.indexOf(u8, remaining, "plugins~Plugin_123") == null);
    try std.testing.expect(std.mem.indexOf(u8, remaining, "\"plugins~Plugin_456\":\"/tmp/two\"") != null);

    try removePluginShareLocalPath(allocator, root, "plugins~Plugin_456");
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, mapping_path, .{}));
}

test "remote share local path recording replaces corrupt mappings" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try dir.dir.createDirPath(io, "home/.tmp");
    try dir.dir.writeFile(io, .{
        .sub_path = "home/.tmp/plugin-share-local-paths-v1.json",
        .data = "not json",
    });

    const root = try dir.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(root);
    try recordPluginShareLocalPath(allocator, root, "plugins~Plugin_789", "/tmp/shared");

    const mapping_path = try pluginShareLocalPathsPath(allocator, root);
    defer allocator.free(mapping_path);
    const remaining = try std.Io.Dir.cwd().readFileAlloc(io, mapping_path, allocator, .limited(1024));
    defer allocator.free(remaining);
    try std.testing.expectEqualStrings(
        "{\"localPluginPathsByRemotePluginId\":{\"plugins~Plugin_789\":\"/tmp/shared\"}}\n",
        remaining,
    );
}

test "remote share endpoint URLs match backend paths" {
    const allocator = std.testing.allocator;
    const list_url = try createdWorkspacePluginsUrl(allocator, "https://chatgpt.com/backend-api/", "next page");
    defer allocator.free(list_url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/ps/plugins/workspace/created?limit=200&pageToken=next%20page", list_url);

    const update_url = try pluginShareTargetsUrl(allocator, "https://chatgpt.com/backend-api/", "plugins~Plugin_123");
    defer allocator.free(update_url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/public/plugins/plugins~Plugin_123/shares", update_url);

    const delete_url = try deletePluginShareUrl(allocator, "https://chatgpt.com/backend-api/", "plugins~Plugin_123");
    defer allocator.free(delete_url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/public/plugins/workspace/plugins~Plugin_123", delete_url);

    const upload_url = try workspacePluginUploadUrl(allocator, "https://chatgpt.com/backend-api/");
    defer allocator.free(upload_url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/public/plugins/workspace/upload-url", upload_url);

    const finalize_create_url = try workspacePluginFinalizeUrl(allocator, "https://chatgpt.com/backend-api/", null);
    defer allocator.free(finalize_create_url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/public/plugins/workspace", finalize_create_url);

    const finalize_update_url = try workspacePluginFinalizeUrl(allocator, "https://chatgpt.com/backend-api/", "plugins~Plugin_123");
    defer allocator.free(finalize_update_url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/public/plugins/workspace/plugins~Plugin_123", finalize_update_url);
}

test "remote skill detail URL appends escaped path segments" {
    const allocator = std.testing.allocator;
    const url = try skillDetailUrl(allocator, "https://chatgpt.com/backend-api/", "plugins~Plugin_123", "plan work");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/ps/plugins/plugins~Plugin_123/skills/plan%20work", url);
}

test "remote uninstall URL matches backend mutation path" {
    const allocator = std.testing.allocator;
    const url = try uninstallPluginUrl(allocator, "https://chatgpt.com/backend-api/", "plugins~Plugin_123");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/plugins/plugins~Plugin_123/uninstall", url);
}

test "remote uninstall cache cleanup removes current and legacy roots" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try dir.dir.createDirPath(io, "home/plugins/cache/chatgpt-global/linear/1.0.0/.codex-plugin");
    try dir.dir.createDirPath(io, "home/plugins/cache/chatgpt-global/plugins~Plugin_123/local/.codex-plugin");
    try dir.dir.writeFile(io, .{
        .sub_path = "home/plugins/cache/chatgpt-global/linear/1.0.0/.codex-plugin/plugin.json",
        .data = "{\"name\":\"linear\"}",
    });
    try dir.dir.writeFile(io, .{
        .sub_path = "home/plugins/cache/chatgpt-global/plugins~Plugin_123/local/.codex-plugin/plugin.json",
        .data = "{\"name\":\"linear\"}",
    });

    const root = try dir.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(root);
    try removeRemotePluginCache(allocator, root, "chatgpt-global", "linear", "plugins~Plugin_123");

    try std.testing.expectError(error.FileNotFound, dir.dir.statFile(io, "home/plugins/cache/chatgpt-global/linear", .{}));
    try std.testing.expectError(error.FileNotFound, dir.dir.statFile(io, "home/plugins/cache/chatgpt-global/plugins~Plugin_123", .{}));
}

test "remote uninstall cache cleanup rejects invalid plugin cache segments" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try dir.dir.createDirPath(io, "home");

    const root = try dir.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(root);

    try std.testing.expectError(
        error.RemotePluginInvalidCachePath,
        removeRemotePluginCache(allocator, root, "chatgpt-global", "linear.v2", "plugins~Plugin_123"),
    );
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
