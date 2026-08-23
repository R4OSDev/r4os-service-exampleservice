const std = @import("std");
const r4os = @import("r4os");

const service_name = "EXSVC";
const service_path = "C:\\R4OS\\SERVICES\\EXSVC.R4X";
const service_args = "/RUN";
const selftest_arg = "/SELFTEST";
const ping_arg = "/PING";
const benchmark_arg = "/BENCHMARK";
const benchmark_keep_arg = "/KEEP";
const benchmark_keep_service_arg = "/BENCHMARKKEEP";
const inventory_restart_limit: u32 = 16;
const inventory_would_block_retry_limit: u32 = 64;
const benchmark_repetitions: usize = 5;
const benchmark_workers: usize = 8;
const benchmark_calls_per_worker: usize = 8;
const benchmark_requests_per_sample: usize = benchmark_workers * benchmark_calls_per_worker;
const benchmark_observation_count: usize = benchmark_repetitions * benchmark_requests_per_sample;
const benchmark_idle_ms: u64 = 2000;
const benchmark_report_path: [*:0]const u8 = "C:\\TEMP\\SVCBENCH.TXT";
const isolation_service_name = "TIMESVC";
const isolation_probe_requests: usize = 32;

const op_echo: u16 = 1;
const op_status: u16 = 2;
const op_benchmark: u16 = 3;
const op_completion_batch: u16 = 4;
const op_no_reply: u16 = 5;
const benchmark_magic: u32 = 0x424D5653;
const completion_magic: u32 = 0x504D4F43;
const completion_batch_size: usize = r4os.abi.service_api_endpoint_queue_depth;
const completion_request_count: usize = completion_batch_size + 1;

const BenchmarkRequest = extern struct {
    magic: u32 = benchmark_magic,
    worker: u16 = 0,
    sequence: u16 = 0,
    sent_ns: u64 = 0,
};

const BenchmarkResponse = extern struct {
    magic: u32 = benchmark_magic,
    worker: u16 = 0,
    sequence: u16 = 0,
    sent_ns: u64 = 0,
    received_ns: u64 = 0,
};

const CompletionRequest = extern struct {
    magic: u32 = completion_magic,
    client_index: u32 = 0,
};

const CompletionResponse = extern struct {
    magic: u32 = completion_magic,
    client_index: u32 = 0,
    arrival_order: u32 = 0,
    reply_order: u32 = 0,
};

const PendingCompletion = struct {
    request_id: u32 = 0,
    client_index: u32 = 0,
    arrival_order: u32 = 0,
};

const BenchmarkObservation = struct {
    queue_ns: u64 = 0,
    e2e_ns: u64 = 0,
    failure: i32 = 1,
};

const Distribution = struct {
    minimum: u64 = 0,
    p50: u64 = 0,
    p95: u64 = 0,
    p99: u64 = 0,
    maximum: u64 = 0,
    mean: u64 = 0,
};

var benchmark_sys: ?r4os.r4sys.Context = null;
var benchmark_services: ?r4os.Services = null;
var benchmark_ready: u32 = 0;
var benchmark_release: u32 = 0;
var benchmark_results: [benchmark_requests_per_sample]BenchmarkObservation = .{BenchmarkObservation{}} ** benchmark_requests_per_sample;

const ServiceStats = struct {
    requests: u32 = 0,
    echoes: u32 = 0,
    status: u32 = 0,
    benchmarks: u32 = 0,
    completion_seen: u32 = 0,
    completion_pending: usize = 0,
    completion_batch_released: bool = false,
    completion_requests: [completion_batch_size]PendingCompletion = .{PendingCompletion{}} ** completion_batch_size,
    bad_ops: u32 = 0,
};

pub fn r4_app_main(app: *r4os.App) i32 {
    const ctx = app.system();
    const services = app.services() orelse return r4os.abi.service_api_result_invalid;
    const benchmark_requested = hasArg(app.args(), benchmark_arg) or hasArg(app.args(), benchmark_keep_service_arg);
    // Service-class binaries may only be launched interactively through the
    // Terminal's explicit selftest policy. The combined test-harness form
    // keeps the benchmark a console-owned process without changing /RUN.
    if (benchmark_requested and hasArg(app.args(), selftest_arg)) {
        return runBenchmark(
            &ctx,
            &services,
            hasArg(app.args(), benchmark_keep_arg) or hasArg(app.args(), benchmark_keep_service_arg),
        );
    }
    if (hasArg(app.args(), selftest_arg)) return runSelfTest(&ctx, &services);
    if (hasArg(app.args(), ping_arg)) return runPingClient(&ctx, &services);
    if (benchmark_requested) {
        return runBenchmark(
            &ctx,
            &services,
            hasArg(app.args(), benchmark_keep_arg) or hasArg(app.args(), benchmark_keep_service_arg),
        );
    }
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
    var service_loop = r4os.ServiceLoop.init(ctx.*, owned_endpoint.raw, .{});
    while (true) {
        switch (service_loop.wait(null)) {
            .requests => |pending| {
                const rc = service_loop.drain(pending, handleRequest, .{ ctx, &owned_endpoint, &stats });
                if (rc >= 0) continue;
                _ = owned_endpoint.unregister();
                return rc;
            },
            .idle, .deadline => {},
            .stop => break,
            .failure => |raw| {
                _ = owned_endpoint.unregister();
                return raw;
            },
        }
    }

    service_loop.report(service_name);
    _ = owned_endpoint.unregister();
    ctx.println("EXSVC stopped cleanly");
    return 0;
}

fn handleRequest(ctx: *const r4os.r4sys.Context, endpoint: *r4os.ServiceEndpoint, stats: *ServiceStats) i32 {
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
    if (message.header.op == op_benchmark) {
        if (message.bytes != @sizeOf(BenchmarkRequest))
            return endpoint.reply(message.header.request_id, r4os.abi.service_api_result_invalid, "SIZE");
        var request: BenchmarkRequest = undefined;
        @memcpy(std.mem.asBytes(&request), payload[0..@sizeOf(BenchmarkRequest)]);
        if (request.magic != benchmark_magic)
            return endpoint.reply(message.header.request_id, r4os.abi.service_api_result_invalid, "MAGIC");
        const received_ns = ctx.monotonicNanoseconds() orelse
            return endpoint.reply(message.header.request_id, r4os.abi.service_api_result_invalid, "CLOCK");
        stats.benchmarks +%= 1;
        const response = BenchmarkResponse{
            .worker = request.worker,
            .sequence = request.sequence,
            .sent_ns = request.sent_ns,
            .received_ns = received_ns,
        };
        return endpoint.replyTyped(BenchmarkResponse, message.header.request_id, r4os.abi.service_api_result_ok, &response);
    }
    if (message.header.op == op_completion_batch) {
        if (message.bytes != @sizeOf(CompletionRequest))
            return endpoint.reply(message.header.request_id, r4os.abi.service_api_result_invalid, "SIZE");
        var request: CompletionRequest = undefined;
        @memcpy(std.mem.asBytes(&request), payload[0..@sizeOf(CompletionRequest)]);
        if (request.magic != completion_magic or request.client_index >= completion_request_count)
            return endpoint.reply(message.header.request_id, r4os.abi.service_api_result_invalid, "REQUEST");

        const arrival_order = stats.completion_seen;
        stats.completion_seen +%= 1;
        if (stats.completion_batch_released) {
            const response = CompletionResponse{
                .client_index = request.client_index,
                .arrival_order = arrival_order,
                .reply_order = arrival_order,
            };
            return endpoint.replyTyped(CompletionResponse, message.header.request_id, r4os.abi.service_api_result_ok, &response);
        }
        if (stats.completion_pending >= stats.completion_requests.len)
            return endpoint.reply(message.header.request_id, r4os.abi.service_api_result_busy, "FULL");
        stats.completion_requests[stats.completion_pending] = .{
            .request_id = message.header.request_id,
            .client_index = request.client_index,
            .arrival_order = arrival_order,
        };
        stats.completion_pending += 1;
        if (stats.completion_pending < completion_batch_size) return 0;

        // Keep all eight endpoint slots occupied long enough for the ninth
        // synchronous worker to enter FIFO admission, then answer the batch
        // in reverse arrival order to exercise request-specific completion.
        ctx.sleepTicks(ctx.ticksFromMilliseconds(50));
        var reply_order: u32 = 0;
        var pending_index = stats.completion_pending;
        while (pending_index > 0) {
            pending_index -= 1;
            const pending = stats.completion_requests[pending_index];
            const response = CompletionResponse{
                .client_index = pending.client_index,
                .arrival_order = pending.arrival_order,
                .reply_order = reply_order,
            };
            const rc = endpoint.replyTyped(CompletionResponse, pending.request_id, r4os.abi.service_api_result_ok, &response);
            if (rc < 0) return rc;
            reply_order += 1;
        }
        stats.completion_pending = 0;
        stats.completion_batch_released = true;
        return 0;
    }
    if (message.header.op == op_no_reply) return 0;
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

fn runBenchmark(ctx: *const r4os.r4sys.Context, services: *const r4os.Services, keep_endpoint: bool) i32 {
    if (!ctx.hasFn("thread_create_handle") or
        !ctx.hasFn("thread_handle_join") or
        !ctx.hasFn("monotonic_clock") or
        !ctx.hasFn("service_start") or
        !ctx.hasFn("service_call")) return benchmarkFail(ctx, 1);

    cleanupService(ctx);
    var info: r4os.abi.ServiceInfo = .{};
    var rc = ctx.serviceInstall(service_name, service_path, service_args, r4os.abi.service_start_manual, "Example service", &info);
    if (rc != r4os.abi.service_api_result_ok) return benchmarkFail(ctx, 2);
    rc = ctx.serviceStart(service_name, &info);
    if (rc != r4os.abi.service_api_result_ok or info.state != r4os.abi.service_state_running)
        return benchmarkFail(ctx, 3);

    var probe = waitServiceOpen(ctx, services, 120) orelse return benchmarkFail(ctx, 4);
    if (!runCompletionScenario(ctx, &probe)) return benchmarkFail(ctx, 12);
    _ = probe.close();
    benchmark_sys = ctx.*;
    benchmark_services = services.*;
    ctx.sleepTicks(ctx.ticksFromMilliseconds(benchmark_idle_ms));

    printBenchmarkMetadata(ctx);
    var all_queue: [benchmark_observation_count]u64 = .{0} ** benchmark_observation_count;
    var all_e2e: [benchmark_observation_count]u64 = .{0} ** benchmark_observation_count;
    var all_offset: usize = 0;

    var sample: usize = 0;
    while (sample < benchmark_repetitions) : (sample += 1) {
        benchmark_results = .{BenchmarkObservation{}} ** benchmark_requests_per_sample;
        @atomicStore(u32, &benchmark_ready, 0, .release);
        @atomicStore(u32, &benchmark_release, 0, .release);

        var handles: [benchmark_workers]r4os.abi.ProgramJoinHandle = .{r4os.abi.ProgramJoinHandle{}} ** benchmark_workers;
        var created: usize = 0;
        while (created < handles.len) : (created += 1) {
            rc = ctx.threadCreateHandle(benchmarkWorkerMain, created, 0, 0, &handles[created]);
            if (rc != r4os.abi.thread_ok) {
                @atomicStore(u32, &benchmark_release, 1, .release);
                joinBenchmarkWorkers(ctx, handles[0..created]);
                return benchmarkFail(ctx, 5);
            }
        }

        var ready_rounds: u32 = 0;
        while (@atomicLoad(u32, &benchmark_ready, .acquire) != benchmark_workers and ready_rounds < 100_000) : (ready_rounds += 1)
            ctx.taskYield();
        if (@atomicLoad(u32, &benchmark_ready, .acquire) != benchmark_workers) {
            @atomicStore(u32, &benchmark_release, 1, .release);
            joinBenchmarkWorkers(ctx, handles[0..]);
            return benchmarkFail(ctx, 6);
        }

        const started_ns = ctx.monotonicNanoseconds() orelse {
            @atomicStore(u32, &benchmark_release, 1, .release);
            joinBenchmarkWorkers(ctx, handles[0..]);
            return benchmarkFail(ctx, 7);
        };
        @atomicStore(u32, &benchmark_release, 1, .release);

        var worker_failures: u32 = 0;
        for (handles[0..]) |*handle| {
            var exit_code: i32 = -1;
            if (ctx.threadHandleJoin(handle, r4os.abi.thread_wait_forever, &exit_code) != r4os.abi.thread_ok or exit_code != 0)
                worker_failures +%= 1;
        }
        const completed_ns = ctx.monotonicNanoseconds() orelse return benchmarkFail(ctx, 8);
        const elapsed_ns = completed_ns -| started_ns;

        var queue_values: [benchmark_requests_per_sample]u64 = .{0} ** benchmark_requests_per_sample;
        var e2e_values: [benchmark_requests_per_sample]u64 = .{0} ** benchmark_requests_per_sample;
        var observation_failures: u32 = 0;
        for (benchmark_results, 0..) |observation, index| {
            const worker = index / benchmark_calls_per_worker;
            const sequence = index % benchmark_calls_per_worker;
            printBenchmarkRaw(ctx, sample, worker, sequence, observation);
            if (observation.failure != 0) observation_failures +%= 1;
            queue_values[index] = observation.queue_ns;
            e2e_values[index] = observation.e2e_ns;
            all_queue[all_offset + index] = observation.queue_ns;
            all_e2e[all_offset + index] = observation.e2e_ns;
        }
        if (worker_failures != 0 or observation_failures != 0 or elapsed_ns == 0)
            return benchmarkFail(ctx, 9);

        const queue_distribution = summarize(queue_values[0..]);
        const e2e_distribution = summarize(e2e_values[0..]);
        const throughput = requestsPerSecond(benchmark_requests_per_sample, elapsed_ns);
        printBenchmarkSample(ctx, sample, elapsed_ns, throughput, queue_distribution, e2e_distribution);
        all_offset += benchmark_requests_per_sample;
        if (sample + 1 < benchmark_repetitions) ctx.sleepTicks(ctx.ticksFromMilliseconds(100));
    }

    printBenchmarkDistribution(ctx, summarize(all_queue[0..all_offset]), summarize(all_e2e[0..all_offset]));
    if (!runEndpointIsolationScenario(ctx, services)) return benchmarkFail(ctx, 13);
    if (keep_endpoint) {
        benchmark_sys = null;
        benchmark_services = null;
        emitBenchmarkLine(ctx, "SVCBENCHOK|1|1", false);
        return 0;
    }
    rc = ctx.serviceStop(service_name, &info, 80);
    if (rc != r4os.abi.service_api_result_ok or info.state != r4os.abi.service_state_stopped)
        return benchmarkFail(ctx, 10);
    rc = ctx.serviceRemove(service_name);
    if (rc != r4os.abi.service_api_result_ok) return benchmarkFail(ctx, 11);
    benchmark_sys = null;
    benchmark_services = null;
    emitBenchmarkLine(ctx, "SVCBENCHOK|1|1", false);
    return 0;
}

fn benchmarkWorkerMain(raw_worker: u64) callconv(.c) i32 {
    var sys = benchmark_sys orelse return 20;
    const services = benchmark_services orelse return 21;
    const worker: usize = @intCast(raw_worker);
    if (worker >= benchmark_workers) return 22;

    var connection = switch (services.open(service_name)) {
        .connection => |value| value,
        .failure => {
            markBenchmarkWorkerFailure(worker, 23);
            _ = @atomicRmw(u32, &benchmark_ready, .Add, 1, .acq_rel);
            return 23;
        },
    };
    _ = @atomicRmw(u32, &benchmark_ready, .Add, 1, .acq_rel);
    while (@atomicLoad(u32, &benchmark_release, .acquire) == 0) sys.taskYield();

    var sequence: usize = 0;
    while (sequence < benchmark_calls_per_worker) : (sequence += 1) {
        const result_index = worker * benchmark_calls_per_worker + sequence;
        const sent_ns = sys.monotonicNanoseconds() orelse {
            benchmark_results[result_index].failure = 24;
            continue;
        };
        const request = BenchmarkRequest{
            .worker = @intCast(worker),
            .sequence = @intCast(sequence),
            .sent_ns = sent_ns,
        };
        const called = connection.callTyped(
            BenchmarkRequest,
            BenchmarkResponse,
            op_benchmark,
            &request,
            r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(2_000_000_000)),
        );
        const response = switch (called) {
            .value => |value| value,
            .timed_out => {
                benchmark_results[result_index].failure = 25;
                continue;
            },
            .remote_failure => |raw| {
                benchmark_results[result_index].failure = raw;
                continue;
            },
            .failure => |raw| {
                benchmark_results[result_index].failure = raw;
                continue;
            },
        };
        const completed_ns = sys.monotonicNanoseconds() orelse {
            benchmark_results[result_index].failure = 26;
            continue;
        };
        if (response.magic != benchmark_magic or
            response.worker != worker or
            response.sequence != sequence or
            response.sent_ns != sent_ns or
            response.received_ns < sent_ns or
            completed_ns < response.received_ns)
        {
            benchmark_results[result_index].failure = 27;
            continue;
        }
        benchmark_results[result_index] = .{
            .queue_ns = response.received_ns - sent_ns,
            .e2e_ns = completed_ns - sent_ns,
            .failure = 0,
        };
    }
    _ = connection.close();
    return 0;
}

fn runEndpointIsolationScenario(ctx: *const r4os.r4sys.Context, services: *const r4os.Services) bool {
    var secondary = waitServiceOpenName(ctx, services, isolation_service_name, 120) orelse return false;
    defer _ = secondary.close();

    benchmark_results = .{BenchmarkObservation{}} ** benchmark_requests_per_sample;
    @atomicStore(u32, &benchmark_ready, 0, .release);
    @atomicStore(u32, &benchmark_release, 0, .release);
    var handles: [benchmark_workers]r4os.abi.ProgramJoinHandle = .{r4os.abi.ProgramJoinHandle{}} ** benchmark_workers;
    var created: usize = 0;
    while (created < handles.len) : (created += 1) {
        if (ctx.threadCreateHandle(benchmarkWorkerMain, created, 0, 0, &handles[created]) != r4os.abi.thread_ok) {
            @atomicStore(u32, &benchmark_release, 1, .release);
            joinBenchmarkWorkers(ctx, handles[0..created]);
            return false;
        }
    }
    var ready_rounds: u32 = 0;
    while (@atomicLoad(u32, &benchmark_ready, .acquire) != benchmark_workers and ready_rounds < 100_000) : (ready_rounds += 1)
        ctx.taskYield();
    if (@atomicLoad(u32, &benchmark_ready, .acquire) != benchmark_workers) {
        @atomicStore(u32, &benchmark_release, 1, .release);
        joinBenchmarkWorkers(ctx, handles[0..]);
        return false;
    }

    printIsolationMetadata(ctx);
    const background_started = ctx.monotonicNanoseconds() orelse {
        @atomicStore(u32, &benchmark_release, 1, .release);
        joinBenchmarkWorkers(ctx, handles[0..]);
        return false;
    };
    @atomicStore(u32, &benchmark_release, 1, .release);
    var probe_values: [isolation_probe_requests]u64 = .{0} ** isolation_probe_requests;
    var probe_failures: u32 = 0;
    var probe: usize = 0;
    while (probe < probe_values.len) : (probe += 1) {
        const started = ctx.monotonicNanoseconds() orelse {
            probe_failures +%= 1;
            printIsolationRaw(ctx, probe, 0, 1);
            continue;
        };
        var response: [@sizeOf(r4os.abi.TimeServiceStatus)]u8 = undefined;
        const call = secondary.call(
            r4os.abi.time_service_op_status,
            "",
            response[0..],
            r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(2_000_000_000)),
        );
        const completed = ctx.monotonicNanoseconds() orelse {
            probe_failures +%= 1;
            printIsolationRaw(ctx, probe, 0, 2);
            continue;
        };
        const ok = switch (call) {
            .response => |value| value.bytes == response.len and value.header.status == r4os.abi.service_api_result_ok,
            else => false,
        };
        if (!ok or completed < started) {
            probe_failures +%= 1;
            printIsolationRaw(ctx, probe, 0, 3);
            continue;
        }
        probe_values[probe] = completed - started;
        printIsolationRaw(ctx, probe, probe_values[probe], 0);
    }

    var worker_failures: u32 = 0;
    for (handles[0..]) |*handle| {
        var exit_code: i32 = -1;
        if (ctx.threadHandleJoin(handle, r4os.abi.thread_wait_forever, &exit_code) != r4os.abi.thread_ok or exit_code != 0)
            worker_failures +%= 1;
    }
    const background_completed = ctx.monotonicNanoseconds() orelse return false;
    var observation_failures: u32 = 0;
    for (benchmark_results) |observation| {
        if (observation.failure != 0) observation_failures +%= 1;
    }
    printIsolationDistribution(
        ctx,
        summarize(probe_values[0..]),
        background_completed -| background_started,
        probe_failures,
        worker_failures,
        observation_failures,
    );
    return probe_failures == 0 and worker_failures == 0 and observation_failures == 0;
}

fn markBenchmarkWorkerFailure(worker: usize, failure: i32) void {
    const first = worker * benchmark_calls_per_worker;
    for (benchmark_results[first .. first + benchmark_calls_per_worker]) |*observation|
        observation.failure = failure;
}

fn joinBenchmarkWorkers(ctx: *const r4os.r4sys.Context, handles: []r4os.abi.ProgramJoinHandle) void {
    for (handles) |*handle| {
        var exit_code: i32 = -1;
        _ = ctx.threadHandleJoin(handle, r4os.abi.thread_wait_forever, &exit_code);
    }
}

fn benchmarkFail(ctx: *const r4os.r4sys.Context, code: u32) i32 {
    var line_buffer: [64]u8 = undefined;
    const line = std.fmt.bufPrint(line_buffer[0..], "SVCBENCHFAIL|1|{d}", .{code}) catch "SVCBENCHFAIL|1|0";
    emitBenchmarkLine(ctx, line, false);
    benchmark_sys = null;
    benchmark_services = null;
    cleanupService(ctx);
    return 1;
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
    if (!runPayloadLifecycleScenario(ctx, &connection)) return fail(ctx, "payload-lifecycle");
    if (!runCompletionScenario(ctx, &connection)) return fail(ctx, "request-completion");
    _ = connection.close();

    rc = ctx.serviceRestart(service_name, &info);
    if (rc != r4os.abi.service_api_result_ok or info.state != r4os.abi.service_state_running or info.instance_id == 0 or info.restart_count == 0) return failCode(ctx, "restart", rc);
    if (!waitInstanceGone(ctx, first_instance, 120)) return fail(ctx, "first-instance-stale");
    const second_instance = info.instance_id;

    connection = waitServiceOpen(ctx, services, 120) orelse return fail(ctx, "open-after-restart");
    if (!callEcho(&connection, "RESTART-OK")) return fail(ctx, "echo-after-restart");

    var stop_header: r4os.abi.ServiceMessageHeader = .{};
    var stop_response: [1]u8 = .{0};
    var stop_request_id: u32 = 0;
    const stop_submit = ctx.ioServiceCall(
        connection.raw,
        op_no_reply,
        "STOP",
        &stop_header,
        stop_response[0..],
        r4os.abi.io_wait_forever,
        0,
        &stop_request_id,
    );
    if (stop_submit != r4os.abi.io_ok or stop_request_id == 0) return fail(ctx, "stop-wait-submit");
    ctx.sleepTicks(ctx.ticksFromMilliseconds(20));

    rc = ctx.serviceStop(service_name, &info, 80);
    if (rc != r4os.abi.service_api_result_ok or info.state != r4os.abi.service_state_stopped) return failCode(ctx, "stop", rc);
    if (!waitInstanceGone(ctx, second_instance, 120)) return fail(ctx, "second-instance-stale");
    var stop_io: r4os.abi.ProgramIoInfo = .{};
    const stop_wait = ctx.ioWait(stop_request_id, r4os.abi.io_wait_forever, &stop_io);
    const stop_result_ok = stop_io.result == r4os.abi.service_api_result_bad_handle or
        stop_io.result == r4os.abi.service_api_result_not_running;
    _ = ctx.ioClose(stop_request_id);
    if (stop_wait != r4os.abi.io_ok or stop_io.state != r4os.abi.io_state_completed or !stop_result_ok)
        return failCode(ctx, "stop-wait-result", stop_io.result);

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

fn runCompletionScenario(ctx: *const r4os.r4sys.Context, connection: *r4os.ServiceConnection) bool {
    var requests: [completion_request_count]CompletionRequest = .{CompletionRequest{}} ** completion_request_count;
    var responses: [completion_request_count]CompletionResponse = .{CompletionResponse{}} ** completion_request_count;
    var headers: [completion_request_count]r4os.abi.ServiceMessageHeader = .{r4os.abi.ServiceMessageHeader{}} ** completion_request_count;
    var io_ids: [completion_request_count]u32 = .{0} ** completion_request_count;
    var submitted: usize = 0;
    while (submitted < completion_request_count) : (submitted += 1) {
        requests[submitted].client_index = @intCast(submitted);
        const rc = ctx.ioServiceCall(
            connection.raw,
            op_completion_batch,
            std.mem.asBytes(&requests[submitted]),
            &headers[submitted],
            std.mem.asBytes(&responses[submitted]),
            ctx.ticksFromMilliseconds(2000),
            0,
            &io_ids[submitted],
        );
        if (rc != r4os.abi.io_ok or io_ids[submitted] == 0) break;
    }
    if (submitted != completion_request_count) {
        cleanupService(ctx);
        closeCompletionRequests(ctx, io_ids[0..submitted]);
        return false;
    }

    var ok = true;
    var index: usize = 0;
    while (index < completion_request_count) : (index += 1) {
        var io_info: r4os.abi.ProgramIoInfo = .{};
        const waited = ctx.ioWait(io_ids[index], ctx.ticksFromMilliseconds(3000), &io_info);
        if (waited != r4os.abi.io_ok or io_info.state != r4os.abi.io_state_completed) {
            cleanupService(ctx);
            closeCompletionRequests(ctx, io_ids[index..]);
            return false;
        }
        if (io_info.result != @as(i32, @intCast(@sizeOf(CompletionResponse))) or
            headers[index].status != r4os.abi.service_api_result_ok or
            responses[index].magic != completion_magic or
            responses[index].client_index != @as(u32, @intCast(index))) ok = false;
        _ = ctx.ioClose(io_ids[index]);
    }

    var arrivals: [completion_request_count]bool = .{false} ** completion_request_count;
    var replies: [completion_request_count]bool = .{false} ** completion_request_count;
    for (responses) |response| {
        if (response.arrival_order >= completion_request_count or response.reply_order >= completion_request_count) {
            ok = false;
            continue;
        }
        const arrival: usize = @intCast(response.arrival_order);
        const reply: usize = @intCast(response.reply_order);
        if (arrivals[arrival] or replies[reply]) ok = false;
        arrivals[arrival] = true;
        replies[reply] = true;
        if (arrival < completion_batch_size) {
            if (response.arrival_order + response.reply_order != completion_batch_size - 1) ok = false;
        } else if (response.arrival_order != completion_batch_size or response.reply_order != completion_batch_size) {
            ok = false;
        }
    }

    var timeout_response: [1]u8 = .{0};
    const timed = connection.call(
        op_no_reply,
        "TIMEOUT",
        timeout_response[0..],
        r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(20_000_000)),
    );
    switch (timed) {
        .timed_out => {},
        else => ok = false,
    }
    return ok;
}

fn closeCompletionRequests(ctx: *const r4os.r4sys.Context, request_ids: []const u32) void {
    for (request_ids) |request_id| {
        if (request_id == 0) continue;
        var info: r4os.abi.ProgramIoInfo = .{};
        _ = ctx.ioWait(request_id, ctx.ticksFromMilliseconds(500), &info);
        _ = ctx.ioClose(request_id);
    }
}

fn callEcho(connection: *r4os.ServiceConnection, payload: []const u8) bool {
    var response: [64]u8 = undefined;
    return callEchoInto(connection, payload, response[0..]);
}

fn callEchoInto(connection: *r4os.ServiceConnection, payload: []const u8, response: []u8) bool {
    const call = connection.call(op_echo, payload, response, r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(120_000_000)));
    if (switch (call) {
        .response => |value| value.bytes != payload.len or value.header.payload_len != payload.len,
        else => true,
    }) return false;
    return bytesEq(response[0..payload.len], payload);
}

fn runPayloadLifecycleScenario(ctx: *const r4os.r4sys.Context, connection: *r4os.ServiceConnection) bool {
    var response: [r4os.abi.service_api_max_payload]u8 = undefined;
    if (!callEchoInto(connection, "", response[0..])) return false;
    if (!callEchoInto(connection, "S", response[0..])) return false;

    var maximum: [r4os.abi.service_api_max_payload]u8 = undefined;
    for (&maximum, 0..) |*byte, index| byte.* = @truncate(index *% 131 +% 17);
    if (!callEchoInto(connection, maximum[0..], response[0..])) return false;

    // Der naechste Ein-Byte-Request nutzt wieder den ersten freien Slot. Ein
    // alter 4096-Byte-Payload darf ueber die neue Laenge nicht sichtbar sein.
    if (!callEchoInto(connection, "R", response[0..])) return false;

    var medium: [257]u8 = undefined;
    for (&medium, 0..) |*byte, index| byte.* = @truncate(index *% 29 +% 3);
    var too_small: [1]u8 = .{0xCC};
    var header: r4os.abi.ServiceMessageHeader = .{};
    const small_result = ctx.serviceCall(
        connection.raw,
        op_echo,
        medium[0..],
        &header,
        too_small[0..],
        ctx.ticksFromMilliseconds(120),
    );
    if (small_result != r4os.abi.service_api_result_buffer_too_small or
        header.magic != r4os.abi.service_api_magic or
        header.payload_len != medium.len or
        too_small[0] != 0xCC) return false;

    // Auch der Buffer-too-small-Abbruch muss den Slot freigeben, ohne dass
    // die 257 alten Bytes in der folgenden leeren Antwort sichtbar werden.
    return callEchoInto(connection, "", response[0..]);
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

fn printBenchmarkMetadata(ctx: *const r4os.r4sys.Context) void {
    var line_buffer: [160]u8 = undefined;
    const line = std.fmt.bufPrint(
        line_buffer[0..],
        "SVCBENCHM|1|{d}|{d}|{d}|{d}|{d}|{d}",
        .{ benchmark_repetitions, benchmark_workers, benchmark_calls_per_worker, benchmark_requests_per_sample, benchmark_observation_count, benchmark_idle_ms },
    ) catch return;
    emitBenchmarkLine(ctx, line, true);
}

fn printBenchmarkRaw(
    ctx: *const r4os.r4sys.Context,
    sample: usize,
    worker: usize,
    sequence: usize,
    observation: BenchmarkObservation,
) void {
    var line_buffer: [192]u8 = undefined;
    const line = std.fmt.bufPrint(
        line_buffer[0..],
        "SVCBENCHR|1|{d}|{d}|{d}|{d}|{d}|{d}",
        .{ sample + 1, worker + 1, sequence + 1, observation.queue_ns, observation.e2e_ns, observation.failure },
    ) catch return;
    emitBenchmarkLine(ctx, line, false);
}

fn printBenchmarkSample(
    ctx: *const r4os.r4sys.Context,
    sample: usize,
    elapsed_ns: u64,
    throughput: u64,
    queue: Distribution,
    e2e: Distribution,
) void {
    var line_buffer: [384]u8 = undefined;
    const line = std.fmt.bufPrint(
        line_buffer[0..],
        "SVCBENCHS|1|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}",
        .{
            sample + 1,
            benchmark_requests_per_sample,
            elapsed_ns,
            throughput,
            queue.minimum,
            queue.p50,
            queue.p95,
            queue.p99,
            queue.maximum,
            queue.mean,
            e2e.minimum,
            e2e.p50,
            e2e.p95,
            e2e.p99,
            e2e.maximum,
            e2e.mean,
        },
    ) catch return;
    emitBenchmarkLine(ctx, line, false);
}

fn printBenchmarkDistribution(ctx: *const r4os.r4sys.Context, queue: Distribution, e2e: Distribution) void {
    var line_buffer: [320]u8 = undefined;
    const line = std.fmt.bufPrint(
        line_buffer[0..],
        "SVCBENCHD|1|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}",
        .{
            benchmark_observation_count,
            queue.minimum,
            queue.p50,
            queue.p95,
            queue.p99,
            queue.maximum,
            queue.mean,
            e2e.minimum,
            e2e.p50,
            e2e.p95,
            e2e.p99,
            e2e.maximum,
            e2e.mean,
        },
    ) catch return;
    emitBenchmarkLine(ctx, line, false);
}

fn printIsolationMetadata(ctx: *const r4os.r4sys.Context) void {
    var line_buffer: [128]u8 = undefined;
    const line = std.fmt.bufPrint(
        line_buffer[0..],
        "SVCISOM|1|{d}|{d}|{d}|{d}",
        .{ benchmark_workers, benchmark_calls_per_worker, benchmark_requests_per_sample, isolation_probe_requests },
    ) catch return;
    emitBenchmarkLine(ctx, line, false);
}

fn printIsolationRaw(ctx: *const r4os.r4sys.Context, probe: usize, elapsed_ns: u64, failure: i32) void {
    var line_buffer: [128]u8 = undefined;
    const line = std.fmt.bufPrint(
        line_buffer[0..],
        "SVCISOR|1|{d}|{d}|{d}",
        .{ probe + 1, elapsed_ns, failure },
    ) catch return;
    emitBenchmarkLine(ctx, line, false);
}

fn printIsolationDistribution(
    ctx: *const r4os.r4sys.Context,
    latency: Distribution,
    background_elapsed_ns: u64,
    probe_failures: u32,
    worker_failures: u32,
    observation_failures: u32,
) void {
    var line_buffer: [320]u8 = undefined;
    const line = std.fmt.bufPrint(
        line_buffer[0..],
        "SVCISOD|1|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}",
        .{
            isolation_probe_requests,
            latency.minimum,
            latency.p50,
            latency.p95,
            latency.p99,
            latency.maximum,
            latency.mean,
            background_elapsed_ns,
            probe_failures,
            worker_failures,
            observation_failures,
        },
    ) catch return;
    emitBenchmarkLine(ctx, line, false);
}

fn emitBenchmarkLine(ctx: *const r4os.r4sys.Context, line: []const u8, reset: bool) void {
    ctx.println(line);
    var file_buffer: [514]u8 = undefined;
    if (line.len + 2 > file_buffer.len) return;
    @memcpy(file_buffer[0..line.len], line);
    file_buffer[line.len] = '\r';
    file_buffer[line.len + 1] = '\n';
    const bytes = file_buffer[0 .. line.len + 2];
    _ = if (reset) ctx.fileWrite(benchmark_report_path, bytes) else ctx.fileAppend(benchmark_report_path, bytes);
}

fn requestsPerSecond(request_count: usize, elapsed_ns: u64) u64 {
    if (request_count == 0 or elapsed_ns == 0) return 0;
    return @intCast((@as(u128, request_count) * 1_000_000_000) / elapsed_ns);
}

fn summarize(values: []const u64) Distribution {
    if (values.len == 0 or values.len > benchmark_observation_count) return .{};
    var sorted: [benchmark_observation_count]u64 = .{0} ** benchmark_observation_count;
    var sum: u128 = 0;
    for (values, 0..) |value, index| {
        sorted[index] = value;
        sum += value;
    }
    insertionSort(sorted[0..values.len]);
    return .{
        .minimum = sorted[0],
        .p50 = nearestRank(sorted[0..values.len], 50),
        .p95 = nearestRank(sorted[0..values.len], 95),
        .p99 = nearestRank(sorted[0..values.len], 99),
        .maximum = sorted[values.len - 1],
        .mean = @intCast(sum / values.len),
    };
}

fn insertionSort(values: []u64) void {
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        const value = values[index];
        var position = index;
        while (position > 0 and values[position - 1] > value) : (position -= 1)
            values[position] = values[position - 1];
        values[position] = value;
    }
}

fn nearestRank(sorted: []const u64, percentile: usize) u64 {
    const rank = (percentile * sorted.len + 99) / 100;
    return sorted[@max(rank, 1) - 1];
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
    return waitServiceOpenName(ctx, services, service_name, max_ticks);
}

fn waitServiceOpenName(ctx: *const r4os.r4sys.Context, services: *const r4os.Services, name: [*:0]const u8, max_ticks: u32) ?r4os.ServiceConnection {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        switch (services.open(name)) {
            .connection => |value| return value,
            .failure => {},
        }
        ctx.sleepTicks(1);
    }
    return switch (services.open(name)) {
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
