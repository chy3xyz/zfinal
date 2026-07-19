const std = @import("std");
const zfinal = @import("zfinal");
const MqttPlugin = zfinal.MqttPlugin;
const AgentPlugin = zfinal.AgentPlugin;
const DidPlugin = zfinal.DidPlugin;
const P2pPlugin = zfinal.P2pPlugin;

/// Edge Computing 演示 - 展示 ZFinal 的边缘计算能力
///
/// 本示例展示如何集成多个插件：
/// - MQTT: 消息队列通信
/// - AI Agent: AI 代理能力
/// - DID: 去中心化身份
/// - P2P: 点对点通信
pub fn main(init: std.process.Init) !void {
    zfinal.io_instance.init(init);
    const allocator = init.gpa;
    const io = init.io;

    // 初始化 ZFinal 应用
    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();

    // === 1. MQTT (QoS0 publish) — connect when broker is available ===
    var mqtt_plugin = MqttPlugin.init(allocator, .{
        .broker_host = "127.0.0.1",
        .broker_port = 1883,
        .client_id = "zfinal-edge-demo",
    });
    try app.addPlugin(mqtt_plugin.plugin());

    // === 2. 配置 AI Agent 插件 ===
    // 用于边缘设备的智能决策
    var agent_plugin = AgentPlugin.init(allocator);
    // 注册自定义工具
    try agent_plugin.registerTool("get_device_status", getDeviceStatus);
    try agent_plugin.registerTool("control_led", controlLed);
    try app.addPlugin(agent_plugin.plugin());

    // === 3. 配置 DID 插件 ===
    // 用于边缘设备的去中心化身份验证
    var did_plugin = try DidPlugin.init(allocator);
    try app.addPlugin(did_plugin.plugin());

    // === 4. 配置 P2P 插件 ===
    // 用于边缘设备之间的直接通信
    var p2p_plugin = try P2pPlugin.init(allocator, 8081);
    defer p2p_plugin.deinit();
    try app.addPlugin(p2p_plugin.plugin());

    // 启动模拟线程（模拟边缘设备数据）
    const sim_thread = try std.Thread.spawn(.{}, simulationLoop, .{ &mqtt_plugin, &did_plugin, &agent_plugin, &p2p_plugin, allocator, io });
    defer sim_thread.detach();

    // 启动应用
    std.debug.print("\n", .{});
    std.debug.print("==============================================\n", .{});
    std.debug.print("  🌐 Edge Computing Demo - 边缘计算演示\n", .{});
    std.debug.print("==============================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Plugins initialized:\n", .{});
    std.debug.print("  ✓ MQTT - 消息队列通信\n", .{});
    std.debug.print("  ✓ AI Agent - AI 智能代理\n", .{});
    std.debug.print("  ✓ DID - 去中心化身份\n", .{});
    std.debug.print("  ✓ P2P - 点对点通信\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Features:\n", .{});
    std.debug.print("  - MQTT pub/sub for device communication\n", .{});
    std.debug.print("  - AI agent with custom tools\n", .{});
    std.debug.print("  - DID signing and verification\n", .{});
    std.debug.print("  - P2P broadcast and discovery\n", .{});
    std.debug.print("\n", .{});

    try app.start();
}

/// 模拟边缘设备数据循环
fn simulationLoop(mqtt: *MqttPlugin, did: *DidPlugin, agent: *AgentPlugin, p2p: *P2pPlugin, allocator: std.mem.Allocator, io: std.Io) !void {
    // 等待插件启动
    std.Io.sleep(io, .{ .nanoseconds = 1 * std.time.ns_per_s }, .awake) catch {};

    // === MQTT 演示（broker 不可用时跳过）===
    mqtt.connect() catch |err| {
        std.debug.print("[MQTT] connect skipped: {t}\n", .{err});
    };
    if (mqtt.connected) {
        try mqtt.publish("zfinal/edge/status", "online");
        try mqtt.publish("zfinal/edge/cpu", "15%");
        try mqtt.publish("zfinal/edge/memory", "42%");
        std.debug.print("[MQTT] Published status messages\n", .{});
    }

    // === DID 演示 ===
    // 对数据进行签名（用于验证数据完整性）
    const sensor_data = "temperature:25.5,humidity:60";
    const signature = try did.sign(sensor_data);
    std.debug.print("[DID] Signed sensor data: {s}\n", .{sensor_data});
    std.debug.print("[DID] Signature: {s}\n", .{signature});

    // === AI Agent 演示 ===
    // 使用 AI 代理处理请求
    const agent_req =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "method": "call_tool",
        \\  "params": {
        \\    "name": "get_device_status",
        \\    "arguments": {}
        \\  },
        \\  "id": 1
        \\}
    ;
    const agent_res = try agent.handleRequest(agent_req);
    std.debug.print("[Agent] Response: {s}\n", .{agent_res});
    allocator.free(agent_res);

    // === P2P 演示 ===
    // 广播消息到其他节点
    try p2p.broadcast("Edge Node 001 Online");
    std.debug.print("[P2P] Broadcast message sent\n", .{});

    std.debug.print("\n[Demo] Simulation complete!\n", .{});
}

/// AI Agent 工具: 获取设备状态
fn getDeviceStatus(ctx: *AgentPlugin, params: ?std.json.Value) anyerror!std.json.Value {
    _ = params;
    var result = std.json.ObjectMap.empty;

    try result.put(ctx.allocator, "device_id", std.json.Value{ .string = "edge-001" });
    try result.put(ctx.allocator, "status", std.json.Value{ .string = "online" });
    try result.put(ctx.allocator, "cpu_usage", std.json.Value{ .float = 15.5 });
    try result.put(ctx.allocator, "memory_usage", std.json.Value{ .float = 42.0 });
    try result.put(ctx.allocator, "temperature", std.json.Value{ .float = 45.0 });
    try result.put(ctx.allocator, "uptime", std.json.Value{ .integer = 3600 });

    return std.json.Value{ .object = result };
}

/// AI Agent 工具: 控制 LED
fn controlLed(ctx: *AgentPlugin, params: ?std.json.Value) anyerror!std.json.Value {
    var result = std.json.ObjectMap.empty;

    if (params) |p| {
        if (p.object.get("state")) |state| {
            const state_str = state.string;
            try result.put(ctx.allocator, "led_state", std.json.Value{ .string = state_str });
            try result.put(ctx.allocator, "message", std.json.Value{ .string = std.fmt.allocPrint(ctx.allocator, "LED turned {s}", .{state_str}) catch "ok" });
        }
    } else {
        try result.put(ctx.allocator, "error", std.json.Value{ .string = "Missing 'state' parameter" });
    }

    return std.json.Value{ .object = result };
}
