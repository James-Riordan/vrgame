const std = @import("std");

fn linkVulkanLoader(
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    b: *std.Build,
) void {
    const os_tag = target.result.os.tag;

    switch (os_tag) {
        .windows => {
            // Try to locate the Vulkan SDK and add its Lib directory.
            const sdk = std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch null;
            if (sdk) |sdk_path| {
                defer b.allocator.free(sdk_path);

                const lib_dir = std.fs.path.join(b.allocator, &.{ sdk_path, "Lib" }) catch null;
                if (lib_dir) |ld| {
                    defer b.allocator.free(ld);
                    exe.addLibraryPath(.{ .cwd_relative = ld });
                }
            }

            // Windows loader name.
            exe.linkSystemLibrary("vulkan-1");
        },
        .linux => {
            exe.linkSystemLibrary("vulkan");
        },
        .macos => {
            // Typically MoltenVK / Vulkan loader (e.g. via VK SDK / Homebrew).
            exe.linkSystemLibrary("vulkan");
        },
        else => {},
    }
}

/// Ensure we have a *workspace* ./registry/vk.xml:
fn ensureVkRegistry(b: *std.Build) std.Build.LazyPath {
    const xml_rel = "registry/vk.xml";
    const registry_dir = "registry";
    const cwd = std.fs.cwd();

    if (cwd.openFile(xml_rel, .{})) |file| {
        file.close();
        return b.path(xml_rel);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => {
            std.debug.print("error: failed to open {s}: {s}\n", .{ xml_rel, @errorName(err) });
            @panic("cannot access registry/vk.xml");
        },
    }

    cwd.makeDir(registry_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            std.debug.print("error: failed to create directory '{s}': {s}\n", .{ registry_dir, @errorName(err) });
            @panic("cannot create registry directory");
        },
    };

    var argv = [_][]const u8{
        "curl",
        "-L",
        "https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/main/xml/vk.xml",
        "-o",
        xml_rel,
    };

    var child = std.process.Child.init(&argv, b.allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        std.debug.print("error: failed to spawn curl for vk.xml: {s}\n", .{@errorName(err)});
        @panic("curl not available or failed to start");
    };

    switch (term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("error: curl (vk.xml) exited with code {d}\n", .{code});
            @panic("failed to download vk.xml");
        },
        else => {
            std.debug.print("error: curl (vk.xml) terminated abnormally: {any}\n", .{term});
            @panic("failed to download vk.xml");
        },
    }

    if (cwd.openFile(xml_rel, .{})) |file2| {
        file2.close();
    } else |err| {
        std.debug.print("error: vk.xml download seems to have succeeded, but cannot reopen {s}: {s}\n", .{ xml_rel, @errorName(err) });
        @panic("vk.xml missing after download");
    }

    return b.path(xml_rel);
}

/// Ensure we have a *workspace* ./registry/xr.xml (pinned to our openxr-zig).
fn ensureXrRegistry(b: *std.Build) std.Build.LazyPath {
    const cwd = std.fs.cwd();
    const registry_dir = "registry";
    const xml_rel = "registry/xr.xml";

    if (std.process.getEnvVarOwned(b.allocator, "VRGAME_XR_XML")) |env_path| {
        defer b.allocator.free(env_path);

        const is_abs = std.fs.path.isAbsolute(env_path);
        const open_result = if (is_abs)
            std.fs.openFileAbsolute(env_path, .{})
        else
            cwd.openFile(env_path, .{});

        if (open_result) |file| {
            file.close();
            std.log.info("Using xr.xml from VRGAME_XR_XML={s}", .{env_path});
            return b.path(env_path);
        } else |err| {
            std.log.warn("VRGAME_XR_XML={s} but failed to open: {s}", .{ env_path, @errorName(err) });
        }
    } else |_| {}

    if (cwd.openFile(xml_rel, .{})) |file| {
        file.close();
        std.log.info("Using existing xr.xml at {s}", .{xml_rel});
        return b.path(xml_rel);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => {
            std.debug.print("error: failed to open {s}: {s}\n", .{ xml_rel, @errorName(err) });
            @panic("cannot access registry/xr.xml");
        },
    }

    cwd.makeDir(registry_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            std.debug.print("error: failed to create directory '{s}': {s}\n", .{ registry_dir, @errorName(err) });
            @panic("cannot create registry directory");
        },
    };

    var argv = [_][]const u8{
        "curl",
        "-L",
        "https://raw.githubusercontent.com/zigadel/openxr-zig/ef4d73159ea71eaf496a83dd108e719e54831b8d/examples/xr.xml",
        "-o",
        xml_rel,
    };

    std.log.info("Downloading xr.xml into {s}", .{xml_rel});

    var child = std.process.Child.init(&argv, b.allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        std.debug.print("error: failed to spawn curl for xr.xml: {s}\n", .{@errorName(err)});
        @panic("curl not available or failed to start");
    };

    switch (term) {
        .Exited => |code| if (code != 0) {
            std.debug.print(
                "error: curl (xr.xml) exited with code {d}\n" ++
                    "hint: manually fetch and save as ./registry/xr.xml if needed\n",
                .{code},
            );
            @panic("failed to download xr.xml");
        },
        else => {
            std.debug.print("error: curl (xr.xml) terminated abnormally: {any}\n", .{term});
            @panic("failed to download xr.xml");
        },
    }

    if (cwd.openFile(xml_rel, .{})) |file2| {
        file2.close();
    } else |err| {
        std.debug.print("error: xr.xml download seems to have succeeded, but cannot reopen {s}: {s}\n", .{
            xml_rel,
            @errorName(err),
        });
        @panic("xr.xml missing after download");
    }

    std.log.info("Successfully downloaded xr.xml into {s}", .{xml_rel});
    return b.path(xml_rel);
}

fn addTestRun(b: *std.Build, root_mod: *std.Build.Module) *std.Build.Step.Run {
    const t = b.addTest(.{ .root_module = root_mod });
    return b.addRunArtifact(t);
}

/// Compile GLSL -> SPIR-V into the build cache and install beside the exe:
/// zig-out/bin/shaders/{triangle_vert,triangle_frag}
fn addShaderBuildSteps(b: *std.Build, exe: *std.Build.Step.Compile, run_step: *std.Build.Step) void {
    var glslc_path: ?[]const u8 = null;

    if (b.findProgram(&.{"glslc"}, &.{}) catch null) |p| {
        glslc_path = p;
        std.log.info("Using glslc in PATH at {s}", .{p});
    } else if (std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch null) |sdk| {
        defer b.allocator.free(sdk);
        const exe_name = if (@import("builtin").os.tag == .windows) "glslc.exe" else "glslc";
        if (std.fs.path.join(b.allocator, &.{ sdk, "Bin", exe_name }) catch null) |candidate| {
            defer b.allocator.free(candidate);
            if (b.findProgram(&.{candidate}, &.{}) catch null) |p2| {
                glslc_path = p2;
                std.log.info("Using glslc from VULKAN_SDK at {s}", .{p2});
            }
        }
    }

    const shaders_step = b.step("shaders", "Build or stage SPIR-V into zig-out/bin/shaders");

    if (glslc_path) |gl| {
        // vertex
        var v_cmd = b.addSystemCommand(&.{ gl, "-c", "-fshader-stage=vert", "shaders/triangle.vert" });
        v_cmd.addArg("-o");
        const v_out = v_cmd.addOutputFileArg("triangle_vert");

        // fragment
        var f_cmd = b.addSystemCommand(&.{ gl, "-c", "-fshader-stage=frag", "shaders/triangle.frag" });
        f_cmd.addArg("-o");
        const f_out = f_cmd.addOutputFileArg("triangle_frag");

        // install beside the exe: zig-out/bin/shaders/*
        const inst_v = b.addInstallFileWithDir(v_out, .bin, "shaders/triangle_vert");
        const inst_f = b.addInstallFileWithDir(f_out, .bin, "shaders/triangle_frag");

        shaders_step.dependOn(&v_cmd.step);
        shaders_step.dependOn(&f_cmd.step);
        shaders_step.dependOn(&inst_v.step);
        shaders_step.dependOn(&inst_f.step);
    } else {
        // Fallback to committed blobs if present
        const cwd = std.fs.cwd();
        var have_vert = true;
        _ = cwd.statFile("shaders/triangle_vert") catch {
            have_vert = false;
        };
        var have_frag = true;
        _ = cwd.statFile("shaders/triangle_frag") catch {
            have_frag = false;
        };

        if (have_vert and have_frag) {
            const inst_v = b.addInstallFileWithDir(b.path("shaders/triangle_vert"), .bin, "shaders/triangle_vert");
            const inst_f = b.addInstallFileWithDir(b.path("shaders/triangle_frag"), .bin, "shaders/triangle_frag");
            shaders_step.dependOn(&inst_v.step);
            shaders_step.dependOn(&inst_f.step);
            std.log.warn("glslc not found; using prebuilt SPIR-V from repo.", .{});
        } else {
            std.log.err(
                "glslc not found and prebuilt SPIR-V missing; expected {s} and {s}. Install Vulkan SDK (glslc) or add blobs.",
                .{ "shaders/triangle_vert", "shaders/triangle_frag" },
            );
            @panic("no SPIR-V available");
        }
    }

    exe.step.dependOn(shaders_step);
    run_step.dependOn(shaders_step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vk_registry = ensureVkRegistry(b);
    const xr_registry = ensureXrRegistry(b);

    // ── Dependencies ──────────────────────────────────────────────────────
    const glfw_dep = b.dependency("glfw_zig", .{ .target = target, .optimize = optimize });
    const glfw_mod = glfw_dep.module("glfw");
    const glfw_lib = glfw_dep.artifact("glfw-zig");

    const vk_dep = b.dependency("vulkan", .{
        .target = target,
        .optimize = optimize,
        .registry = vk_registry,
    });
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

    // ── Modules ───────────────────────────────────────────────────────────

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

    const game_mod = b.createModule(.{
        .root_source_file = b.path("src/game/game.zig"),
        .target = target,
        .optimize = optimize,
    });

    const camera3d_mod = b.createModule(.{
        .root_source_file = b.path("src/game/camera3d.zig"),
        .target = target,
        .optimize = optimize,
    });
    camera3d_mod.addImport("math3d", math3d_mod);

    const vrgame_root = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    vrgame_root.addImport("graphics_context", graphics_context_mod);
    vrgame_root.addImport("swapchain", swapchain_mod);
    vrgame_root.addImport("vertex", vertex_mod);
    vrgame_root.addImport("frame_time", frame_time_mod);
    vrgame_root.addImport("game", game_mod);
    vrgame_root.addImport("math3d", math3d_mod);
    vrgame_root.addImport("camera3d", camera3d_mod);

    // ── Executable (root: src/main.zig) ───────────────────────────────────
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
    exe_mod.addImport("game", game_mod);
    exe_mod.addImport("vrgame", vrgame_root);
    exe_mod.addImport("math3d", math3d_mod);
    exe_mod.addImport("camera3d", camera3d_mod);

    const exe = b.addExecutable(.{
        .name = "vrgame",
        .root_module = exe_mod,
    });

    // OpenXR codegen before building exe.
    exe.step.dependOn(&xr_gen_cmd.step);

    // GLFW lib + Vulkan loader
    exe.linkLibrary(glfw_lib);
    linkVulkanLoader(exe, target, b);

    // Install
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run vrgame");
    run_step.dependOn(&run_cmd.step);

    // Auto-compile shaders → SPIR-V blobs consumed by @embedFile
    addShaderBuildSteps(b, exe, run_step);

    // ── Tests (ZTable-style) ──────────────────────────────────────────────
    const unit_step = b.step("test-unit", "Run unit tests (vrgame modules)");
    const integration_step = b.step("test-integration", "Run integration tests");
    const e2e_step = b.step("test-e2e", "Run end-to-end tests");

    const run_main_tests = addTestRun(b, exe_mod);
    const run_graphics_context_tests = addTestRun(b, graphics_context_mod);
    const run_swapchain_tests = addTestRun(b, swapchain_mod);
    const run_vertex_tests = addTestRun(b, vertex_mod);
    const run_frame_time_tests = addTestRun(b, frame_time_mod);
    const run_game_tests = addTestRun(b, game_mod);
    const run_vrgame_root_tests = addTestRun(b, vrgame_root);
    const run_math3d_tests = addTestRun(b, math3d_mod);
    const run_camera3d_tests = addTestRun(b, camera3d_mod);

    unit_step.dependOn(&run_main_tests.step);
    unit_step.dependOn(&run_graphics_context_tests.step);
    unit_step.dependOn(&run_swapchain_tests.step);
    unit_step.dependOn(&run_vertex_tests.step);
    unit_step.dependOn(&run_frame_time_tests.step);
    unit_step.dependOn(&run_game_tests.step);
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
        integration_mod.addImport("game", game_mod);
        integration_mod.addImport("vrgame", vrgame_root);

        const integration_tests = b.addTest(.{ .root_module = integration_mod });
        const run_integration = b.addRunArtifact(integration_tests);
        integration_step.dependOn(&run_integration.step);
    }

    const have_e2e = blk: {
        _ = std.fs.cwd().statFile("tests/test_all_e2e.zig") catch break :blk false;
        break :blk true;
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
        e2e_mod.addImport("game", game_mod);
        e2e_mod.addImport("vrgame", vrgame_root);

        const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
        const run_e2e = b.addRunArtifact(e2e_tests);
        e2e_step.dependOn(&run_e2e.step);
    }

    const test_all_step = b.step("test-all", "Build vrgame and run unit + integration + e2e tests");
    test_all_step.dependOn(b.getInstallStep());
    test_all_step.dependOn(unit_step);
    test_all_step.dependOn(integration_step);
    test_all_step.dependOn(e2e_step);

    const test_step = b.step("test", "Alias for test-all");
    test_step.dependOn(test_all_step);

    b.default_step = test_all_step;
}
