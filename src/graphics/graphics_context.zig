const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const vk = @import("vulkan");

const Allocator = std.mem.Allocator;

const GetInstanceProc = *const fn (vk.Instance, [*:0]const u8) callconv(.c) vk.PfnVoidFunction;
const GetDeviceProc = *const fn (vk.Device, [*:0]const u8) callconv(.c) vk.PfnVoidFunction;

// ─────────────────────────────────────────────────────────────────────────────
// Optional instance extensions (portability on macOS)
// ─────────────────────────────────────────────────────────────────────────────
const optional_instance_extensions = blk: {
    if (builtin.os.tag == .macos) {
        break :blk [_][*:0]const u8{
            vk.extensions.khr_get_physical_device_properties_2.name,
            vk.extensions.khr_portability_enumeration.name,
        };
    } else {
        break :blk [_][*:0]const u8{
            vk.extensions.khr_get_physical_device_properties_2.name,
        };
    }
};

// Device extensions
const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
};
const optional_device_extensions = [_][*:0]const u8{};

// Dispatch aliases (modern vulkan-zig)
const BaseDispatch = vk.BaseWrapper;
const InstanceDispatch = vk.InstanceWrapper;
const DeviceDispatch = vk.DeviceWrapper;

// Module-scope flag toggled by GLFW framebuffer callback
var g_need_swapchain_recreate: bool = false;

pub const GraphicsContext = struct {
    // Vulkan dispatchers
    vkb: BaseDispatch,
    vki: InstanceDispatch,
    vkd: DeviceDispatch,

    // Core handles
    instance: vk.Instance,
    surface: vk.SurfaceKHR,
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,
    dev: vk.Device,

    // Queues
    graphics_queue: Queue,
    present_queue: Queue,

    // Keep the window so we can query framebuffer pixels
    window: *glfw.Window,
    resize_requested: bool = false,

    pub fn init(
        allocator: Allocator,
        app_name: [*:0]const u8,
        window: *glfw.Window,
    ) !GraphicsContext {
        var self: GraphicsContext = undefined;
        self.window = window;

        // Base dispatch via GLFW proc adapter
        const get_proc: GetInstanceProc = glfwGetInstanceProc;
        self.vkb = BaseDispatch.load(get_proc);

        // Instance extensions (GLFW + optional)
        const glfw_exts_opt = glfw.getRequiredInstanceExtensions(allocator) catch |err| {
            if (glfw.getLastError()) |info| {
                const code_opt = glfw.errorCodeFromC(info.code);
                const code_str = if (code_opt) |c| @tagName(c) else "UnknownError";
                const desc_str: []const u8 = info.description orelse "no description";
                std.log.err("GLFW Vulkan extensions failed: {s}: {s}", .{ code_str, desc_str });
            } else {
                std.log.err("GLFW Vulkan extensions failed: {s}", .{@errorName(err)});
            }
            return error.VulkanInstanceExtensionsQueryFailed;
        };
        const glfw_exts = glfw_exts_opt orelse {
            std.log.err("GLFW reported no required Vulkan instance extensions", .{});
            return error.VulkanInstanceExtensionsMissing;
        };

        var instance_extensions = try std.ArrayList([*:0]const u8).initCapacity(
            allocator,
            glfw_exts.len + optional_instance_extensions.len,
        );
        defer instance_extensions.deinit(allocator);

        for (glfw_exts) |ext_name_z| {
            try instance_extensions.append(allocator, ext_name_z.ptr);
        }

        var ext_count: u32 = 0;
        _ = try self.vkb.enumerateInstanceExtensionProperties(null, &ext_count, null);
        const propsv = try allocator.alloc(vk.ExtensionProperties, ext_count);
        defer allocator.free(propsv);
        _ = try self.vkb.enumerateInstanceExtensionProperties(null, &ext_count, propsv.ptr);

        for (optional_instance_extensions) |ext_name| {
            const want = std.mem.span(ext_name);
            for (propsv) |p| {
                const nlen = std.mem.indexOfScalar(u8, &p.extension_name, 0) orelse p.extension_name.len;
                if (std.mem.eql(u8, p.extension_name[0..nlen], want)) {
                    try instance_extensions.append(allocator, ext_name);
                    break;
                }
            }
        }

        const app_version: u32 = @as(u32, @bitCast(vk.makeApiVersion(0, 0, 0, 0)));
        const api_version: u32 = @as(u32, @bitCast(vk.makeApiVersion(0, 1, 0, 0))); // Vulkan 1.0

        const app_info = vk.ApplicationInfo{
            .p_application_name = app_name,
            .application_version = app_version,
            .p_engine_name = app_name,
            .engine_version = app_version,
            .api_version = api_version,
        };

        const enabled_ext_count: u32 = @intCast(instance_extensions.items.len);
        const enabled_ext_ptr: [*]const [*:0]const u8 = @ptrCast(instance_extensions.items.ptr);

        self.instance = try self.vkb.createInstance(&vk.InstanceCreateInfo{
            .flags = if (builtin.os.tag == .macos)
                .{ .enumerate_portability_bit_khr = true }
            else
                .{},
            .p_application_info = &app_info,
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = undefined,
            .enabled_extension_count = enabled_ext_count,
            .pp_enabled_extension_names = enabled_ext_ptr,
        }, null);

        // Instance/device dispatch
        const get_inst_proc: GetInstanceProc = self.vkb.dispatch.vkGetInstanceProcAddr.?;
        self.vki = InstanceDispatch.load(self.instance, get_inst_proc);
        errdefer self.vki.destroyInstance(self.instance, null);

        self.surface = try createSurface(self.instance, window);
        errdefer self.vki.destroySurfaceKHR(self.instance, self.surface, null);

        const candidate = try pickPhysicalDevice(self.vki, self.instance, allocator, self.surface);
        self.pdev = candidate.pdev;
        self.props = candidate.props;

        self.dev = try initializeCandidate(allocator, self.vki, candidate);
        const get_dev_proc: GetDeviceProc = self.vki.dispatch.vkGetDeviceProcAddr.?;
        self.vkd = DeviceDispatch.load(self.dev, get_dev_proc);
        errdefer self.vkd.destroyDevice(self.dev, null);

        self.graphics_queue = Queue.init(self.vkd, self.dev, candidate.queues.graphics_family);
        self.present_queue = Queue.init(self.vkd, self.dev, candidate.queues.present_family);

        self.mem_props = self.vki.getPhysicalDeviceMemoryProperties(self.pdev);

        // Install framebuffer resize callback (sets a module-scope flag)
        self.installFramebufferResizeCallback();

        return self;
    }

    pub fn deinit(self: GraphicsContext) void {
        _ = self.vkd.deviceWaitIdle(self.dev) catch {};
        self.vkd.destroyDevice(self.dev, null);
        self.vki.destroySurfaceKHR(self.instance, self.surface, null);
        self.vki.destroyInstance(self.instance, null);
    }

    /// Width/height in **framebuffer pixels** (Retina-aware).
    pub fn framebufferExtent(self: *const GraphicsContext) vk.Extent2D {
        const fb = glfw.getFramebufferSize(self.window);
        const w: i32 = if (fb.width < 1) 1 else fb.width;
        const h: i32 = if (fb.height < 1) 1 else fb.height;
        return .{ .width = @intCast(w), .height = @intCast(h) };
    }

    /// Returns true once when the OS reports framebuffer size change.
    pub fn takeResizeFlag(_: *GraphicsContext) bool {
        const r = g_need_swapchain_recreate;
        g_need_swapchain_recreate = false;
        return r;
    }

    pub fn installFramebufferResizeCallback(self: *GraphicsContext) void {
        glfw.setWindowUserPointer(self.window, self);
        _ = glfw.setFramebufferSizeCallback(self.window, framebufferSizeChanged);
    }

    pub fn deviceName(self: *const GraphicsContext) []const u8 {
        return std.mem.sliceTo(self.props.device_name[0..], 0);
    }

    pub fn findMemoryTypeIndex(self: GraphicsContext, memory_type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
        for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |mem_type, i| {
            const bit: u32 = (@as(u32, 1)) << @as(u5, @truncate(i));
            if (memory_type_bits & bit != 0 and mem_type.property_flags.contains(flags))
                return @intCast(i);
        }
        return error.NoSuitableMemoryType;
    }

    pub fn allocate(self: GraphicsContext, reqs: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags) !vk.DeviceMemory {
        return try self.vkd.allocateMemory(self.dev, &.{
            .allocation_size = reqs.size,
            .memory_type_index = try self.findMemoryTypeIndex(reqs.memory_type_bits, flags),
        }, null);
    }
};

// ── Queues ───────────────────────────────────────────────────────────────────
pub const Queue = struct {
    handle: vk.Queue,
    family: u32,
    fn init(vkd: DeviceDispatch, dev: vk.Device, family: u32) Queue {
        return .{ .handle = vkd.getDeviceQueue(dev, family, 0), .family = family };
    }
};

// ── GLFW proc adapter ─────────────────────────────────────────────────────────
fn glfwGetInstanceProc(instance: vk.Instance, name: [*:0]const u8) callconv(.c) vk.PfnVoidFunction {
    const opaque_instance: ?*anyopaque = blk: {
        if (instance == .null_handle) break :blk null;
        break :blk @ptrFromInt(@intFromEnum(instance));
    };
    const name_slice: [:0]const u8 = std.mem.span(name);
    const raw: glfw.VkProc = glfw.getInstanceProcAddress(opaque_instance, name_slice);
    if (raw) |p| return @ptrCast(p);
    return null;
}

// ── Surface creation (GLFW → VkSurfaceKHR) ───────────────────────────────────
extern fn glfwCreateWindowSurface(instance: vk.Instance, window: *glfw.Window, allocator: ?*const anyopaque, surface: *vk.SurfaceKHR) vk.Result;

fn createSurface(instance: vk.Instance, window: *glfw.Window) !vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;
    const res = glfwCreateWindowSurface(instance, window, null, &surface);
    if (res != .success) return error.SurfaceInitFailed;
    return surface;
}

// ── Device selection, queues, extensions ─────────────────────────────────────
const DeviceCandidate = struct { pdev: vk.PhysicalDevice, props: vk.PhysicalDeviceProperties, queues: QueueAllocation };
const QueueAllocation = struct { graphics_family: u32, present_family: u32 };

fn pickPhysicalDevice(vki: InstanceDispatch, instance: vk.Instance, allocator: Allocator, surface: vk.SurfaceKHR) !DeviceCandidate {
    var n: u32 = 0;
    _ = try vki.enumeratePhysicalDevices(instance, &n, null);
    const pdevs = try allocator.alloc(vk.PhysicalDevice, n);
    defer allocator.free(pdevs);
    _ = try vki.enumeratePhysicalDevices(instance, &n, pdevs.ptr);

    for (pdevs) |pdev| {
        if (try checkSuitable(vki, pdev, allocator, surface)) |c| return c;
    }
    return error.NoSuitableDevice;
}

fn checkSuitable(vki: InstanceDispatch, pdev: vk.PhysicalDevice, allocator: Allocator, surface: vk.SurfaceKHR) !?DeviceCandidate {
    const props = vki.getPhysicalDeviceProperties(pdev);
    if (!try checkExtensionSupport(vki, pdev, allocator)) return null;
    if (!try checkSurfaceSupport(vki, pdev, surface)) return null;
    if (try allocateQueues(vki, pdev, allocator, surface)) |q| {
        return .{ .pdev = pdev, .props = props, .queues = q };
    }
    return null;
}

fn allocateQueues(vki: InstanceDispatch, pdev: vk.PhysicalDevice, allocator: Allocator, surface: vk.SurfaceKHR) !?QueueAllocation {
    var count: u32 = 0;
    vki.getPhysicalDeviceQueueFamilyProperties(pdev, &count, null);
    const families = try allocator.alloc(vk.QueueFamilyProperties, count);
    defer allocator.free(families);
    vki.getPhysicalDeviceQueueFamilyProperties(pdev, &count, families.ptr);

    var gfx: ?u32 = null;
    var prs: ?u32 = null;

    for (families, 0..) |props, i| {
        const idx: u32 = @intCast(i);
        if (gfx == null and props.queue_flags.graphics_bit) gfx = idx;

        if (prs == null) {
            const s: vk.Bool32 = try vki.getPhysicalDeviceSurfaceSupportKHR(pdev, idx, surface);
            if (@intFromEnum(s) != 0) prs = idx;
        }
    }

    if (gfx != null and prs != null) return .{ .graphics_family = gfx.?, .present_family = prs.? };
    return null;
}

fn checkSurfaceSupport(vki: InstanceDispatch, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var f: u32 = 0;
    _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &f, null);
    var m: u32 = 0;
    _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &m, null);
    return f > 0 and m > 0;
}

fn checkExtensionSupport(vki: InstanceDispatch, pdev: vk.PhysicalDevice, allocator: Allocator) !bool {
    var n: u32 = 0;
    _ = try vki.enumerateDeviceExtensionProperties(pdev, null, &n, null);
    const propsv = try allocator.alloc(vk.ExtensionProperties, n);
    defer allocator.free(propsv);
    _ = try vki.enumerateDeviceExtensionProperties(pdev, null, &n, propsv.ptr);

    for (required_device_extensions) |ext_name| {
        const want = std.mem.span(ext_name);
        var found = false;
        for (propsv) |p| {
            const len = std.mem.indexOfScalar(u8, &p.extension_name, 0) orelse p.extension_name.len;
            if (std.mem.eql(u8, p.extension_name[0..len], want)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn initializeCandidate(allocator: Allocator, vki: InstanceDispatch, cand: DeviceCandidate) !vk.Device {
    const priority = [_]f32{1.0};
    const qci = [_]vk.DeviceQueueCreateInfo{
        .{ .flags = .{}, .queue_family_index = cand.queues.graphics_family, .queue_count = 1, .p_queue_priorities = &priority },
        .{ .flags = .{}, .queue_family_index = cand.queues.present_family, .queue_count = 1, .p_queue_priorities = &priority },
    };
    const queue_count: u32 = if (cand.queues.graphics_family == cand.queues.present_family) 1 else 2;

    var dev_exts = try std.ArrayList([*:0]const u8).initCapacity(allocator, required_device_extensions.len);
    defer dev_exts.deinit(allocator);
    try dev_exts.appendSlice(allocator, required_device_extensions[0..]);

    // Optionals per device (safe no-op if missing)
    var n: u32 = 0;
    _ = try vki.enumerateDeviceExtensionProperties(cand.pdev, null, &n, null);
    const propsv = try allocator.alloc(vk.ExtensionProperties, n);
    defer allocator.free(propsv);
    _ = try vki.enumerateDeviceExtensionProperties(cand.pdev, null, &n, propsv.ptr);

    for (optional_device_extensions) |name| {
        const want = std.mem.span(name);
        for (propsv) |p| {
            const len = std.mem.indexOfScalar(u8, &p.extension_name, 0) orelse p.extension_name.len;
            if (std.mem.eql(u8, p.extension_name[0..len], want)) {
                try dev_exts.append(allocator, name);
                break;
            }
        }
    }

    return try vki.createDevice(cand.pdev, &.{
        .flags = .{},
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &qci,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
        .enabled_extension_count = @intCast(dev_exts.items.len),
        .pp_enabled_extension_names = @as([*]const [*:0]const u8, @ptrCast(dev_exts.items.ptr)),
        .p_enabled_features = null,
    }, null);
}

// GLFW callback → set the module-scope flag
fn framebufferSizeChanged(win: ?*glfw.Window, _: c_int, _: c_int) callconv(.c) void {
    if (win) |w| {
        if (glfw.getWindowUserPointer(w)) |p| {
            const gc: *GraphicsContext = @ptrCast(@alignCast(p));
            gc.resize_requested = true;
        }
    }
}
