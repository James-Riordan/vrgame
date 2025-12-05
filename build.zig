// (unchanged)
const std = @import("std");

// ──────────────────────────────────────────────────────────────────────────────
// Vulkan loader linking
// ──────────────────────────────────────────────────────────────────────────────
fn linkVulkanLoader(
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    b: *std.Build,
) void {
    switch (target.result.os.tag) {
        .windows => {
            if (std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch null) |sdk_path| {
                defer b.allocator.free(sdk_path);
                if (std.fs.path.join(b.allocator, &.{ sdk_path, "Lib" }) catch null) |ld| {
                    defer b.allocator.free(ld);
                    exe.addLibraryPath(.{ .cwd_relative = ld });
                }
            }
            exe.linkSystemLibrary("vulkan-1");
        },
        .linux, .macos => exe.linkSystemLibrary("vulkan"),
        else => {},
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Registry helpers (download to ./registry if missing)
// ──────────────────────────────────────────────────────────────────────────────
fn ensureVkRegistry(b: *std.Build) std.Build.LazyPath {
    const rel = "registry/vk.xml";
    if (std.fs.cwd().openFile(rel, .{})) |f| {
        f.close();
        return b.path(rel);
    } else |err| {
        if (err != error.FileNotFound) {
            std.debug.print("error: open {s}: {s}\n", .{ rel, @errorName(err) });
            @panic("cannot access registry/vk.xml");
        }
    }

    std.fs.cwd().makeDir("registry") catch |e| if (e != error.PathAlreadyExists) {
        std.debug.print("error: mkdir registry: {s}\n", .{@errorName(e)});
        @panic("cannot create registry dir");
    };

    var argv = [_][]const u8{
        "curl",
        "-L",
        "https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/main/xml/vk.xml",
        "-o",
        rel,
    };
    var child = std.process.Child.init(&argv, b.allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = child.spawnAndWait() catch |e| {
        std.debug.print("error: curl vk.xml: {s}\n", .{@errorName(e)});
        @panic("curl not available");
    };
    switch (term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("error: curl vk.xml exit {d}\n", .{code});
            @panic("failed to download vk.xml");
        },
        else => {
            std.debug.print("error: curl vk.xml abnormal: {any}\n", .{term});
            @panic("failed to download vk.xml");
        },
    }
    return b.path(rel);
}

fn ensureXrRegistry(b: *std.Build) std.Build.LazyPath {
    const rel = "registry/xr.xml";
    if (std.process.getEnvVarOwned(b.allocator, "VRGAME_XR_XML") catch null) |envp| {
        defer b.allocator.free(envp);
        const open_res = if (std.fs.path.isAbsolute(envp))
            std.fs.openFileAbsolute(envp, .{})
        else
            std.fs.cwd().openFile(envp, .{});
        if (open_res) |f| {
            f.close();
            std.log.info("Using xr.xml from VRGAME_XR_XML={s}", .{envp});
            return b.path(envp);
        } else |e| {
            std.log.warn("VRGAME_XR_XML={s} open failed: {s}", .{ envp, @errorName(e) });
        }
    }

    if (std.fs.cwd().openFile(rel, .{})) |f| {
        f.close();
        std.log.info("Using existing xr.xml at {s}", .{rel});
        return b.path(rel);
    } else |err| {
        if (err != error.FileNotFound) {
            std.debug.print("error: open {s}: {s}\n", .{ rel, @errorName(err) });
            @panic("cannot access registry/xr.xml");
        }
    }

    std.fs.cwd().makeDir("registry") catch |e| if (e != error.PathAlreadyExists) {
        std.debug.print("error: mkdir registry: {s}\n", .{@errorName(e)});
        @panic("cannot create registry dir");
    };

    std.log.info("Downloading xr.xml into {s}", .{rel});
    var argv = [_][]const u8{
        "curl",
        "-L",
        "https://raw.githubusercontent.com/zigadel/openxr-zig/ef4d73159ea71eaf496a83dd108e719e54831b8d/examples/xr.xml",
        "-o",
        rel,
    };
    var child = std.process.Child.init(&argv, b.allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = child.spawnAndWait() catch |e| {
        std.debug.print("error: curl xr.xml: {s}\n", .{@errorName(e)});
        @panic("curl not available");
    };
    switch (term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("error: curl xr.xml exit {d}\n", .{code});
            @panic("failed to download xr.xml");
        },
        else => {
            std.debug.print("error: curl xr.xml abnormal: {any}\n", .{term});
            @panic("failed to download xr.xml");
        },
    }
    return b.path(rel);
}

fn fileExists(rel: []const u8) bool {
    _ = std.fs.cwd().access(rel, .{}) catch return false;
    return true;
}

fn detectStage(stem: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, stem, ".vert")) return "vert";
    if (std.mem.endsWith(u8, stem, ".frag")) return "frag";
    return null;
}

fn addShaderBuildSteps(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) *std.Build.Step {
    const SRC_DIRS = [_][]const u8{ "assets/shaders", "shaders" };

    const glslc: ?[]const u8 = b.findProgram(&.{"glslc"}, &.{}) catch null;
    if (glslc) |p| {
        std.log.info("Using glslc at {s}", .{p});
    } else {
        std.log.warn("glslc not found; will only stage existing .spv files from {s}/ or {s}/", .{ SRC_DIRS[0], SRC_DIRS[1] });
    }

    const shaders_step = b.step("shaders", "Build or stage SPIR-V into zig-out/bin/shaders");

    const stems = [_][]const u8{
        "DEBUG_flat.vert",
        "DEBUG_flat.frag",
        "basic_lit.vert",
        "basic_lit.frag",
        "triangle.vert",
        "triangle.frag",
    };

    const is_macos = (target.result.os.tag == .macos);
    const ubo_binding = if (is_macos) "1" else "0";
    const tex_binding = if (is_macos) "0" else "1";

    var missing_count: usize = 0;

    for (stems) |stem| {
        const stage = detectStage(stem) orelse {
            std.log.warn("Unknown shader stage for {s}; expected .vert or .frag", .{stem});
            missing_count += 1;
            continue;
        };

        const out_spv_name = b.fmt("{s}.spv", .{stem});
        const install_dest = b.fmt("shaders/{s}", .{out_spv_name});

        var found = false;

        for (SRC_DIRS) |src_dir| {
            const src_glsl_rel = b.fmt("{s}/{s}", .{ src_dir, stem });
            const src_spv_rel = b.fmt("{s}/{s}.spv", .{ src_dir, stem });

            if (glslc != null and fileExists(src_glsl_rel)) {
                var cmd = b.addSystemCommand(&.{ glslc.?, "-O", "-c", b.fmt("-fshader-stage={s}", .{stage}) });
                cmd.addArg(b.fmt("-DUBO_BINDING={s}", .{ubo_binding}));
                cmd.addArg(b.fmt("-DTEX_BINDING={s}", .{tex_binding}));
                cmd.addFileArg(b.path(src_glsl_rel));
                cmd.addArg("-o");
                const out_lp = cmd.addOutputFileArg(out_spv_name);

                const inst = b.addInstallFileWithDir(out_lp, .bin, install_dest);
                shaders_step.dependOn(&cmd.step);
                shaders_step.dependOn(&inst.step);
                found = true;
                break;
            }

            if (fileExists(src_spv_rel)) {
                const inst2 = b.addInstallFileWithDir(b.path(src_spv_rel), .bin, install_dest);
                shaders_step.dependOn(&inst2.step);
                found = true;
                break;
            }
        }

        if (!found) {
            std.log.warn("Shader missing: {s} (looked in {s}/ and {s}/)", .{ stem, SRC_DIRS[0], SRC_DIRS[1] });
            missing_count += 1;
        }
    }

    exe.step.dependOn(shaders_step);
    return shaders_step;
}

// ──────────────────────────────────────────────────────────────────────────────
// Test helper
// ──────────────────────────────────────────────────────────────────────────────
fn addTestRun(b: *std.Build, root_mod: *std.Build.Module) *std.Build.Step.Run {
    const t = b.addTest(.{ .root_module = root_mod });
    return b.addRunArtifact(t);
}

// ──────────────────────────────────────────────────────────────────────────────
// Build graph
// ──────────────────────────────────────────────────────────────────────────────
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vk_registry = ensureVkRegistry(b);
    const xr_registry = ensureXrRegistry(b);

    // ── External deps
    const glfw_dep = b.dependency("glfw_zig", .{ .target = target, .optimize = optimize });
    const glfw_mod = glfw_dep.module("glfw");
    const glfw_lib = glfw_dep.artifact("glfw-zig");

    const vk_dep = b.dependency("vulkan", .{ .target = target, .optimize = optimize, .registry = vk_registry });
    const vk_mod = vk_dep.module("vulkan-zig");

    const xr_dep = b.dependency("openxr", .{ .target = target, .optimize = optimize });
    const xr_gen_exe = xr_dep.artifact("openxr-zig-generator");
    const xr_gen_cmd = b.addRunArtifact(xr_gen_exe);
    xr_gen_cmd.addFileArg(xr_registry);
    const xr_zig = xr_gen_cmd.addOutputFileArg("xr.zig");
    const xr_mod = b.createModule(.{
        .root_source_file = xr_zig,
        .target = target,
        .optimize = optimize,
    });

    // ── Project modules
    const math3d_mod = b.createModule(.{
        .root_source_file = b.path("src/math/math3d.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vertex_mod = b.createModule(.{
        .root_source_file = b.path("src/graphics/vertex.zig"),
        .target = target,
        .optimize = optimize,
    });
    vertex_mod.addImport("vulkan", vk_mod);
    vertex_mod.addImport("math3d", math3d_mod);

    const graphics_context_mod = b.createModule(.{
        .root_source_file = b.path("src/graphics/graphics_context.zig"),
        .target = target,
        .optimize = optimize,
    });
    graphics_context_mod.addImport("glfw", glfw_mod);
    graphics_context_mod.addImport("vulkan", vk_mod);
    graphics_context_mod.addImport("openxr", xr_mod);
    graphics_context_mod.addImport("vertex", vertex_mod);

    const swapchain_mod = b.createModule(.{
        .root_source_file = b.path("src/graphics/swapchain.zig"),
        .target = target,
        .optimize = optimize,
    });
    swapchain_mod.addImport("vulkan", vk_mod);
    swapchain_mod.addImport("graphics_context", graphics_context_mod);
    swapchain_mod.addImport("vertex", vertex_mod);

    const frame_time_mod = b.createModule(.{
        .root_source_file = b.path("src/game/frame_time.zig"),
        .target = target,
        .optimize = optimize,
    });

    const camera3d_mod = b.createModule(.{
        .root_source_file = b.path("src/game/camera3d.zig"),
        .target = target,
        .optimize = optimize,
    });
    camera3d_mod.addImport("math3d", math3d_mod);

    const texture_mod = b.createModule(.{
        .root_source_file = b.path("src/graphics/texture.zig"),
        .target = target,
        .optimize = optimize,
    });
    texture_mod.addImport("vulkan", vk_mod);
    texture_mod.addImport("graphics_context", graphics_context_mod);

    const depth_mod = b.createModule(.{
        .root_source_file = b.path("src/graphics/depth.zig"),
        .target = target,
        .optimize = optimize,
    });
    depth_mod.addImport("vulkan", vk_mod);

    const scroll_mod = b.createModule(.{
        .root_source_file = b.path("src/input/scroll.zig"),
        .target = target,
        .optimize = optimize,
    });

    const orbit_mod = b.createModule(.{
        .root_source_file = b.path("src/game/orbit.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vrgame_root = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    vrgame_root.addImport("graphics_context", graphics_context_mod);
    vrgame_root.addImport("swapchain", swapchain_mod);
    vrgame_root.addImport("vertex", vertex_mod);
    vrgame_root.addImport("frame_time", frame_time_mod);
    vrgame_root.addImport("math3d", math3d_mod);
    vrgame_root.addImport("camera3d", camera3d_mod);

    // ── Executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("glfw", glfw_mod);
    exe_mod.addImport("vulkan", vk_mod);
    exe_mod.addImport("openxr", xr_mod);
    exe_mod.addImport("graphics_context", graphics_context_mod);
    exe_mod.addImport("swapchain", swapchain_mod);
    exe_mod.addImport("vertex", vertex_mod);
    exe_mod.addImport("frame_time", frame_time_mod);
    exe_mod.addImport("vrgame", vrgame_root);
    exe_mod.addImport("math3d", math3d_mod);
    exe_mod.addImport("camera3d", camera3d_mod);
    exe_mod.addImport("depth", depth_mod);
    exe_mod.addImport("texture", texture_mod);
    exe_mod.addImport("mouse_scroll", scroll_mod);
    exe_mod.addImport("orbit", orbit_mod);

    const exe = b.addExecutable(.{
        .name = "vrgame",
        .root_module = exe_mod,
    });

    // OpenXR generator
    exe.step.dependOn(&xr_gen_cmd.step);

    // GLFW + Vulkan
    exe.linkLibrary(glfw_lib);
    linkVulkanLoader(exe, target, b);

    // Install exe
    b.installArtifact(exe);

    // Shaders
    const shaders_step = addShaderBuildSteps(b, exe, target);

    // Run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.step.dependOn(shaders_step);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run vrgame");
    run_step.dependOn(&run_cmd.step);

    // ── Tests
    const unit_step = b.step("test-unit", "Run unit tests (modules)");
    const integration_step = b.step("test-integration", "Run integration tests");
    const e2e_step = b.step("test-e2e", "Run end-to-end tests");

    const run_main_tests = addTestRun(b, exe_mod);
    const run_graphics_context_tests = addTestRun(b, graphics_context_mod);
    const run_swapchain_tests = addTestRun(b, swapchain_mod);
    const run_vertex_tests = addTestRun(b, vertex_mod);
    const run_frame_time_tests = addTestRun(b, frame_time_mod);
    const run_vrgame_root_tests = addTestRun(b, vrgame_root);
    const run_math3d_tests = addTestRun(b, math3d_mod);
    const run_camera3d_tests = addTestRun(b, camera3d_mod);

    inline for ([_]*std.Build.Step.Run{
        run_main_tests,
        run_graphics_context_tests,
        run_swapchain_tests,
        run_vertex_tests,
        run_frame_time_tests,
        run_vrgame_root_tests,
        run_math3d_tests,
        run_camera3d_tests,
    }) |r| {
        r.step.dependOn(&xr_gen_cmd.step);
        r.step.dependOn(shaders_step);
    }

    unit_step.dependOn(&run_main_tests.step);
    unit_step.dependOn(&run_graphics_context_tests.step);
    unit_step.dependOn(&run_swapchain_tests.step);
    unit_step.dependOn(&run_vertex_tests.step);
    unit_step.dependOn(&run_frame_time_tests.step);
    unit_step.dependOn(&run_vrgame_root_tests.step);
    unit_step.dependOn(&run_math3d_tests.step);
    unit_step.dependOn(&run_camera3d_tests.step);

    const have_integration = blk: {
        _ = std.fs.cwd().statFile("tests/test_all_integration.zig") catch break :blk false;
        break :blk true;
    };
    if (have_integration) {
        const integration_mod = b.createModule(.{
            .root_source_file = b.path("tests/test_all_integration.zig"),
            .target = target,
            .optimize = optimize,
        });
        integration_mod.addImport("glfw", glfw_mod);
        integration_mod.addImport("vulkan", vk_mod);
        integration_mod.addImport("openxr", xr_mod);
        integration_mod.addImport("graphics_context", graphics_context_mod);
        integration_mod.addImport("swapchain", swapchain_mod);
        integration_mod.addImport("math3d", math3d_mod);
        integration_mod.addImport("vertex", vertex_mod);
        integration_mod.addImport("frame_time", frame_time_mod);
        integration_mod.addImport("vrgame", vrgame_root);
        integration_mod.addImport("camera3d", camera3d_mod);

        const integration_tests = b.addTest(.{ .root_module = integration_mod });
        integration_tests.step.dependOn(&xr_gen_cmd.step);
        integration_tests.step.dependOn(shaders_step);

        const run_integration = b.addRunArtifact(integration_tests);
        integration_step.dependOn(&run_integration.step);
    }

    const have_e2e = blk2: {
        _ = std.fs.cwd().statFile("tests/test_all_e2e.zig") catch break :blk2 false;
        break :blk2 true;
    };
    if (have_e2e) {
        const e2e_mod = b.createModule(.{
            .root_source_file = b.path("tests/test_all_e2e.zig"),
            .target = target,
            .optimize = optimize,
        });
        e2e_mod.addImport("glfw", glfw_mod);
        e2e_mod.addImport("vulkan", vk_mod);
        e2e_mod.addImport("openxr", xr_mod);
        e2e_mod.addImport("graphics_context", graphics_context_mod);
        e2e_mod.addImport("swapchain", swapchain_mod);
        e2e_mod.addImport("vertex", vertex_mod);
        e2e_mod.addImport("frame_time", frame_time_mod);
        e2e_mod.addImport("vrgame", vrgame_root);
        e2e_mod.addImport("math3d", math3d_mod);
        e2e_mod.addImport("camera3d", camera3d_mod);

        const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
        e2e_tests.step.dependOn(&xr_gen_cmd.step);
        e2e_tests.step.dependOn(shaders_step);

        const run_e2e = b.addRunArtifact(e2e_tests);
        e2e_step.dependOn(&run_e2e.step);
    }

    const test_all_step = b.step("test-all", "Build vrgame + run unit, integration, and e2e tests");
    test_all_step.dependOn(b.getInstallStep());
    test_all_step.dependOn(unit_step);
    test_all_step.dependOn(integration_step);
    test_all_step.dependOn(e2e_step);

    const test_step = b.step("test", "Alias for test-all");
    test_step.dependOn(test_all_step);

    b.default_step = test_all_step;
}
