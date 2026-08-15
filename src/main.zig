const r4os = @import("r4os");

const service_name = "EXSVC";
const service_path = "C:\\R4OS\\SERVICES\\EXSVC.R4X";
const service_args = "/RUN";
const selftest_arg = "/SELFTEST";
const ping_arg = "/PING";
const inventory_restart_limit: u32 = 16;
const inventory_would_block_retry_limit: u32 = 64;

const op_echo: u16 = 1;
const op_status: u16 = 2;

const ServiceStats = struct {
    requests: u32 = 0,
    echoes: u32 = 0,
    status: u32 = 0,
    bad_ops: u32 = 0,
};

pub fn r4_app_main(app: *r4os.App) i32 {
    const ctx = app.system();
    const services = app.services() orelse return r4os.abi.service_api_result_invalid;
    if (hasArg(app.args(), selftest_arg)) return runSelfTest(&ctx, &services);
    if (hasArg(app.args(), ping_arg)) return runPingClient(&ctx, &services);
    return runService(&ctx, &services);
}

fn runService(ctx: *const r4os.r4sys.Context, services: *const r4os.Services) i32 {
    var endpoint: ?r4os.ServiceEndpoint = null;
    var waited: u32 = 0;
    while (waited < 100 and endpoint == null) : (waited += 1) {
        switch (services.register(service_name, 0)) {
            .endpoint => |value| {
                endpoint = value;
                ctx.write("EXSVC endpoint handle=");
                ctx.printU64(@intCast(value.raw));
                ctx.println("");
            },
            .failure => {},
        }
        ctx.sleepTicks(1);
    }
    if (endpoint == null) {
        ctx.println("EXSVC endpoint registration failed");
        return r4os.abi.service_api_result_no_endpoint;
    }

    var owned_endpoint = endpoint.?;
    var stats: ServiceStats = .{};
    while (!ctx.programShouldClose()) {
        const wait = owned_endpoint.wait(r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(1_000_000)));
        switch (wait) {
            .ready => {
                const rc = handleRequest(&owned_endpoint, &stats);
                if (rc < 0) {
                    _ = owned_endpoint.unregister();
                    return rc;
                }
            },
            .timed_out => {},
            .failure => |raw| {
                _ = owned_endpoint.unregister();
                return raw;
            },
        }
    }

    _ = owned_endpoint.unregister();
    ctx.println("EXSVC stopped cleanly");
    return 0;
}

fn handleRequest(endpoint: *r4os.ServiceEndpoint, stats: *ServiceStats) i32 {
    var payload: [r4os.abi.service_api_max_payload]u8 = undefined;
    const message = switch (endpoint.recv(payload[0..])) {
        .message => |value| value,
        .would_block => return 0,
        .failure => |raw| return raw,
    };

    stats.requests +%= 1;
    if (message.header.op == op_echo) {
        stats.echoes +%= 1;
        return endpoint.reply(message.header.request_id, r4os.abi.service_api_result_ok, payload[0..message.bytes]);
    }
    if (message.header.op == op_status) {
        stats.status +%= 1;
        return endpoint.reply(message.header.request_id, r4os.abi.service_api_result_ok, "EXSVC OK");
    }
    stats.bad_ops +%= 1;
    return endpoint.reply(message.header.request_id, r4os.abi.service_api_result_bad_op, "BADOP");
}

fn runPingClient(ctx: *const r4os.r4sys.Context, services: *const r4os.Services) i32 {
    ctx.println("EXSVC ping");
    var connection = waitServiceOpen(ctx, services, 100) orelse {
        ctx.println("EXSVC ping failed: service not open");
        return 1;
    };
    var response: [32]u8 = undefined;
    const call = connection.call(op_echo, "PING", response[0..], r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(100_000_000)));
    _ = connection.close();
    if (switch (call) {
        .response => |value| value.bytes != 4,
        else => true,
    } or !bytesEq(response[0..4], "PING")) {
        ctx.println("EXSVC ping failed");
        return 1;
    }
    ctx.println("EXSVC ping: OK");
    return 0;
}

fn runSelfTest(ctx: *const r4os.r4sys.Context, services: *const r4os.Services) i32 {
    ctx.println("EXSVC selftest");
    if (!ctx.hasFn("service_start")) return fail(ctx, "manager-api");
    if (!ctx.hasFn("service_call")) return fail(ctx, "service-api");

    cleanupService(ctx);

    const class = ctx.programClass(service_path, .auto);
    if (class != @intFromEnum(r4os.abi.ProgramClass.service)) return failCode(ctx, "class", class);

    var info: r4os.abi.ServiceInfo = .{};
    var rc = ctx.serviceInstall(service_name, service_path, service_args, r4os.abi.service_start_manual, "Example service", &info);
    if (rc != r4os.abi.service_api_result_ok) return failCode(ctx, "install", rc);

    var detail: r4os.abi.ServiceDetail = .{};
    rc = ctx.serviceDetailByName(service_name, &detail);
    if (rc != r4os.abi.service_api_result_ok) return failCode(ctx, "detail", rc);
    if (!bytesEq(spanZ(detail.path[0..]), service_path)) return fail(ctx, "detail-path");
    if (!bytesEq(spanZ(detail.args[0..]), service_args)) return fail(ctx, "detail-args");

    rc = ctx.serviceStart(service_name, &info);
    if (rc != r4os.abi.service_api_result_ok or info.state != r4os.abi.service_state_running or info.instance_id == 0) return failCode(ctx, "start", rc);
    const first_instance = info.instance_id;

    var connection = waitServiceOpen(ctx, services, 120) orelse return fail(ctx, "open");
    if (!callEcho(&connection, "EXSVC-0.22.6")) return fail(ctx, "echo");
    if (!callStatus(&connection)) return fail(ctx, "status");
    _ = connection.close();

    rc = ctx.serviceRestart(service_name, &info);
    if (rc != r4os.abi.service_api_result_ok or info.state != r4os.abi.service_state_running or info.instance_id == 0 or info.restart_count == 0) return failCode(ctx, "restart", rc);
    if (!waitInstanceGone(ctx, first_instance, 120)) return fail(ctx, "first-instance-stale");
    const second_instance = info.instance_id;

    connection = waitServiceOpen(ctx, services, 120) orelse return fail(ctx, "open-after-restart");
    if (!callEcho(&connection, "RESTART-OK")) return fail(ctx, "echo-after-restart");

    rc = ctx.serviceStop(service_name, &info, 80);
    if (rc != r4os.abi.service_api_result_ok or info.state != r4os.abi.service_state_stopped) return failCode(ctx, "stop", rc);
    if (!waitInstanceGone(ctx, second_instance, 120)) return fail(ctx, "second-instance-stale");

    var stale_response: [16]u8 = undefined;
    const stale = connection.call(op_status, "X", stale_response[0..], r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(5_000_000)));
    const stale_code = switch (stale) {
        .failure => |raw| raw,
        else => 0,
    };
    _ = connection.close();
    if (stale_code != r4os.abi.service_api_result_bad_handle and stale_code != r4os.abi.service_api_result_not_running) return failCode(ctx, "stale-handle", stale_code);

    rc = ctx.serviceRemove(service_name);
    if (rc != r4os.abi.service_api_result_ok) return failCode(ctx, "remove", rc);
    rc = ctx.serviceStatus(service_name, &info);
    if (rc != r4os.abi.service_api_result_not_found) return failCode(ctx, "remove-status", rc);
    const removed_open = services.open(service_name);
    if (switch (removed_open) {
        .failure => |raw| raw != r4os.abi.service_api_result_not_found,
        else => true,
    }) return fail(ctx, "remove-open");

    ctx.println("EXSVC selftest: OK");
    return 0;
}

fn callEcho(connection: *r4os.ServiceConnection, payload: []const u8) bool {
    var response: [64]u8 = undefined;
    const call = connection.call(op_echo, payload, response[0..], r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(120_000_000)));
    if (switch (call) {
        .response => |value| value.bytes != payload.len,
        else => true,
    }) return false;
    return bytesEq(response[0..payload.len], payload);
}

fn callStatus(connection: *r4os.ServiceConnection) bool {
    var response: [32]u8 = undefined;
    const call = connection.call(op_status, "STATUS", response[0..], r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(120_000_000)));
    if (switch (call) {
        .response => |value| value.bytes != 8,
        else => true,
    }) return false;
    return bytesEq(response[0..8], "EXSVC OK");
}

fn cleanupService(ctx: *const r4os.r4sys.Context) void {
    var info: r4os.abi.ServiceInfo = .{};
    const rc = ctx.serviceStatus(service_name, &info);
    if (rc != r4os.abi.service_api_result_ok) return;
    if (info.state == r4os.abi.service_state_running or info.state == r4os.abi.service_state_starting or info.state == r4os.abi.service_state_stopping) {
        _ = ctx.serviceStop(service_name, &info, 80);
    }
    _ = ctx.serviceRemove(service_name);
}

fn waitServiceOpen(ctx: *const r4os.r4sys.Context, services: *const r4os.Services, max_ticks: u32) ?r4os.ServiceConnection {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        switch (services.open(service_name)) {
            .connection => |value| return value,
            .failure => {},
        }
        ctx.sleepTicks(1);
    }
    return switch (services.open(service_name)) {
        .connection => |value| value,
        .failure => null,
    };
}

fn waitInstanceGone(ctx: *const r4os.r4sys.Context, id: u32, max_ticks: u32) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        if (!instanceExists(ctx, id)) return true;
        ctx.sleepTicks(1);
    }
    return !instanceExists(ctx, id);
}

fn instanceExists(ctx: *const r4os.r4sys.Context, id: u32) bool {
    var attempt: u32 = 0;
    restart: while (attempt < inventory_restart_limit) : (attempt += 1) {
        var cursor: r4os.abi.ProgramInventoryCursor = .{};
        var summary: r4os.abi.ProgramInventorySummary = .{};
        if (!beginProgramInventory(ctx, &cursor, &summary)) return true;
        while (true) {
            var entries: [@as(usize, r4os.abi.program_inventory_page_max)]r4os.abi.ProgramInstanceSnapshot = undefined;
            var page: r4os.abi.ProgramInventoryPageInfo = .{};
            if (!readProgramInventoryPage(ctx, &cursor, entries[0..], &page)) return true;
            if (page.status == r4os.abi.program_inventory_status_restart) continue :restart;
            if (page.returned > entries.len or page.snapshot_generation != cursor.snapshot_generation) return true;
            for (entries[0..@intCast(page.returned)]) |entry| {
                if (entry.info.id == id) return true;
            }
            if (page.status == r4os.abi.program_inventory_status_complete) return false;
            if (page.status != r4os.abi.program_inventory_status_more or page.returned == 0) return true;
        }
    }
    // An unstable inventory must not be mistaken for a completed stop.
    return true;
}

fn beginProgramInventory(
    ctx: *const r4os.r4sys.Context,
    cursor: *r4os.abi.ProgramInventoryCursor,
    summary: *r4os.abi.ProgramInventorySummary,
) bool {
    var retry: u32 = 0;
    while (retry <= inventory_would_block_retry_limit) : (retry += 1) {
        cursor.* = .{};
        summary.* = .{};
        const status = ctx.programInventoryBegin(cursor, summary);
        if (status == r4os.abi.program_handle_ok) return true;
        if (status != r4os.abi.program_handle_error_would_block or retry == inventory_would_block_retry_limit)
            return false;
        ctx.sleepTicks(1);
    }
    return false;
}

fn readProgramInventoryPage(
    ctx: *const r4os.r4sys.Context,
    cursor: *r4os.abi.ProgramInventoryCursor,
    entries: []r4os.abi.ProgramInstanceSnapshot,
    page: *r4os.abi.ProgramInventoryPageInfo,
) bool {
    var retry: u32 = 0;
    while (retry <= inventory_would_block_retry_limit) : (retry += 1) {
        const cursor_before = cursor.*;
        page.* = .{};
        const status = ctx.programInventoryPrograms(cursor, entries, page);
        if (status == r4os.abi.program_handle_ok) return true;
        cursor.* = cursor_before;
        page.* = .{};
        if (status != r4os.abi.program_handle_error_would_block or retry == inventory_would_block_retry_limit)
            return false;
        ctx.sleepTicks(1);
    }
    return false;
}

fn fail(ctx: *const r4os.r4sys.Context, label: []const u8) i32 {
    ctx.write("EXSVC selftest FAILED: ");
    ctx.println(label);
    cleanupService(ctx);
    return 1;
}

fn failCode(ctx: *const r4os.r4sys.Context, label: []const u8, code: i32) i32 {
    ctx.write("EXSVC selftest FAILED: ");
    ctx.write(label);
    ctx.write(" code=");
    ctx.printI32(code);
    ctx.println("");
    cleanupService(ctx);
    return 1;
}

fn hasArg(args: []const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < args.len and args[offset] != 0) {
        while (offset < args.len and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < args.len and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn spanZ(value: []const u8) []const u8 {
    var len: usize = 0;
    while (len < value.len and value[len] != 0) : (len += 1) {}
    return value[0..len];
}

fn bytesEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - ('a' - 'A');
    return ch;
}
