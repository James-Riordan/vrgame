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
        else => {
            // Other OSes: do nothing. If a Vulkan loader is required but missing,
            // link will fail loud and clear.
        },
    }
}

/// Ensure we have a *workspace* ./registry/vk.xml:
/// - If ./registry/vk.xml exists, just use it.
/// - Otherwise:
///   - mkdir ./registry (if needed),
///   - run `curl -L <vk.xml> -o registry/vk.xml` once,
///   - then use that.
///
/// This returns a LazyPath suitable for `.registry` in the `vulkan` dependency.
fn ensureVkRegistry(b: *std.Build) std.Build.LazyPath {
    const xml_rel = "registry/vk.xml";
    const registry_dir = "registry";
    const cwd = std.fs.cwd();

    // 1) If the file already exists in the repo, we're done.
    if (cwd.openFile(xml_rel, .{})) |file| {
        file.close();
        return b.path(xml_rel);
    } else |err| switch (err) {
        error.FileNotFound => {}, // expected first-time case
        else => {
            std.debug.print("error: failed to open {s}: {s}\n", .{
                xml_rel,
                @errorName(err),
            });
            @panic("cannot access registry/vk.xml");
        },
    }

    // 2) Make sure ./registry exists.
    cwd.makeDir(registry_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            std.debug.print("error: failed to create directory '{s}': {s}\n", .{
                registry_dir,
                @errorName(err),
            });
            @panic("cannot create registry directory");
        },
    };

    // 3) Download vk.xml into ./registry/vk.xml using curl, synchronously.
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

    // 4) Sanity check that vk.xml is now really there.
    if (cwd.openFile(xml_rel, .{})) |file2| {
        file2.close();
    } else |err| {
        std.debug.print("error: vk.xml download seems to have succeeded, but cannot reopen {s}: {s}\n", .{
            xml_rel,
            @errorName(err),
        });
        @panic("vk.xml missing after download");
    }

    return b.path(xml_rel);
}

/// Ensure we have a *workspace* ./registry/xr.xml that is
/// compatible with the vendored `openxr-zig` commit.
///
/// Strategy:
/// - Optional env override: VRGAME_XR_XML (absolute or relative).
/// - Else, if ./registry/xr.xml exists, trust it and use it (no network).
/// - Else (first run):
///   - mkdir ./registry (if needed),
///   - run `curl -L <pinned xr.xml> -o registry/xr.xml` once,
///   - then use that.
///
/// Once xr.xml exists, we *never* re-download it unless you delete it.
fn ensureXrRegistry(b: *std.Build) std.Build.LazyPath {
    const cwd = std.fs.cwd();
    const registry_dir = "registry";
    const xml_rel = "registry/xr.xml";

    // 0) Optional env override for power users.
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
    } else |_| {
        // no VRGAME_XR_XML, that's fine
    }

    // 1) If ./registry/xr.xml already exists, trust it.
    if (cwd.openFile(xml_rel, .{})) |file| {
        file.close();
        std.log.info("Using existing xr.xml at {s}", .{xml_rel});
        return b.path(xml_rel);
    } else |err| switch (err) {
        error.FileNotFound => {}, // normal first-time case
        else => {
            std.debug.print("error: failed to open {s}: {s}\n", .{
                xml_rel,
                @errorName(err),
            });
            @panic("cannot access registry/xr.xml");
        },
    }

    // 2) Make sure ./registry exists.
    cwd.makeDir(registry_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            std.debug.print("error: failed to create directory '{s}': {s}\n", .{
                registry_dir,
                @errorName(err),
            });
            @panic("cannot create registry directory");
        },
    };

    // 3) Download the xr.xml that matches the pinned openxr-zig commit.
    //
    // Commit is the same one as in build.zig.zon:
    //   ef4d73159ea71eaf496a83dd108e719e54831b8d
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
                    "hint: if this is a TLS / schannel issue on Windows, you can:\n" ++
                    "  - Manually fetch:\n" ++
                    "      https://raw.githubusercontent.com/zigadel/openxr-zig/ef4d73159ea71eaf496a83dd108e719e54831b8d/examples/xr.xml\n" ++
                    "    and save it as ./registry/xr.xml\n",
                .{code},
            );
            @panic("failed to download xr.xml");
        },
        else => {
            std.debug.print(
                "error: curl (xr.xml) terminated abnormally: {any}\n",
                .{term},
            );
            @panic("failed to download xr.xml");
        },
    }

    // 4) Sanity check that xr.xml is now really there.
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

/// Tiny helper mirroring ZTable style: add a `zig test` for a module and
/// wrap it in a run step so it participates in the build graph cleanly.
fn addTestRun(b: *std.Build, root_mod: *std.Build.Module) *std.Build.Step.Run {
    const t = b.addTest(.{ .root_module = root_mod });
    return b.addRunArtifact(t);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Resolve / auto-download registries up front.
    const vk_registry = ensureVkRegistry(b);
    const xr_registry = ensureXrRegistry(b);

    // ─────────────────────────────────────────────────────────────────────
    // Dependencies
    // ─────────────────────────────────────────────────────────────────────

    // glfw-zig (your repo), as declared in build.zig.zon under .glfw_zig.
    const glfw_dep = b.dependency("glfw_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const glfw_mod = glfw_dep.module("glfw");
    const glfw_lib = glfw_dep.artifact("glfw-zig");

    // vulkan-zig (Snektron), declared in build.zig.zon under .vulkan.
    const vk_dep = b.dependency("vulkan", .{
        .target = target,
        .optimize = optimize,
        .registry = vk_registry,
    });
    const vk_mod = vk_dep.module("vulkan-zig");

    // openxr-zig (your fork), declared in build.zig.zon under .openxr.
    const xr_dep = b.dependency("openxr", .{
        .target = target,
        .optimize = optimize,
    });
    const xr_gen_exe = xr_dep.artifact("openxr-zig-generator");

    const xr_gen_cmd = b.addRunArtifact(xr_gen_exe);
    xr_gen_cmd.addFileArg(xr_registry);
    const xr_zig = xr_gen_cmd.addOutputFileArg("xr.zig");

    const xr_mod = b.createModule(.{
        .root_source_file = xr_zig,
        .target = target,
        .optimize = optimize,
    });

    // ─────────────────────────────────────────────────────────────────────
    // Internal modules (full module wiring, ZTable-style)
    // ─────────────────────────────────────────────────────────────────────

    const vertex_mod = b.createModule(.{
        .root_source_file = b.path("src/graphics/vertex.zig"),
        .target = target,
        .optimize = optimize,
    });
    vertex_mod.addImport("vulkan", vk_mod);

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

    // ─────────────────────────────────────────────────────────────────────
    // Root module for vrgame (exe entrypoint)
    // ─────────────────────────────────────────────────────────────────────

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("glfw", glfw_mod);
    exe_mod.addImport("vulkan", vk_mod);
    exe_mod.addImport("openxr", xr_mod); // use as: const xr = @import("openxr");
    exe_mod.addImport("graphics_context", graphics_context_mod);
    exe_mod.addImport("swapchain", swapchain_mod);
    exe_mod.addImport("vertex", vertex_mod);

    // ─────────────────────────────────────────────────────────────────────
    // Shader compilation (glslc → SPIR-V → @embedFile)
    // ─────────────────────────────────────────────────────────────────────

    // Vertex shader → triangle_vert.spv → anonymous import "triangle_vert".
    const compile_vert_shader = b.addSystemCommand(&.{"glslc"});
    compile_vert_shader.addFileArg(b.path("shaders/triangle.vert"));
    compile_vert_shader.addArgs(&.{ "--target-env=vulkan1.1", "-o" });
    const triangle_vert_spv = compile_vert_shader.addOutputFileArg("triangle_vert.spv");
    exe_mod.addAnonymousImport("triangle_vert", .{
        .root_source_file = triangle_vert_spv,
    });

    // Fragment shader → triangle_frag.spv → anonymous import "triangle_frag".
    const compile_frag_shader = b.addSystemCommand(&.{"glslc"});
    compile_frag_shader.addFileArg(b.path("shaders/triangle.frag"));
    compile_frag_shader.addArgs(&.{ "--target-env=vulkan1.1", "-o" });
    const triangle_frag_spv = compile_frag_shader.addOutputFileArg("triangle_frag.spv");
    exe_mod.addAnonymousImport("triangle_frag", .{
        .root_source_file = triangle_frag_spv,
    });

    // ─────────────────────────────────────────────────────────────────────
    // Executable + run step
    // ─────────────────────────────────────────────────────────────────────

    const exe = b.addExecutable(.{
        .name = "vrgame",
        .root_module = exe_mod,
    });

    // The executable (and any tests importing openxr) must wait for the
    // OpenXR bindings to be generated. Using xr_zig as root_source_file
    // already wires the dependency; this is just an explicit reminder.
    exe.step.dependOn(&xr_gen_cmd.step);

    // Pull in glfw-zig (which brings GLFW C and platform libs along).
    exe.linkLibrary(glfw_lib);

    // Pull in the Vulkan loader for the host OS.
    linkVulkanLoader(exe, target, b);

    // Install the exe as the default artifact.
    b.installArtifact(exe);

    // `zig build run` convenience.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Vulkan + OpenXR triangle demo");
    run_step.dependOn(&run_cmd.step);

    // ─────────────────────────────────────────────────────────────────────
    // Tests – ZTable-style, but per-module (no test_all_unit.zig)
    // ─────────────────────────────────────────────────────────────────────

    const unit_step = b.step("test-unit", "Run unit tests (vrgame modules)");
    const integration_step = b.step("test-integration", "Run integration tests");
    const e2e_step = b.step("test-e2e", "Run end-to-end tests");

    // --- Unit: each module runs its inline `test` blocks ------------------

    const run_main_tests = addTestRun(b, exe_mod);
    const run_graphics_context_tests = addTestRun(b, graphics_context_mod);
    const run_swapchain_tests = addTestRun(b, swapchain_mod);
    const run_vertex_tests = addTestRun(b, vertex_mod);

    unit_step.dependOn(&run_main_tests.step);
    unit_step.dependOn(&run_graphics_context_tests.step);
    unit_step.dependOn(&run_swapchain_tests.step);
    unit_step.dependOn(&run_vertex_tests.step);

    // --- Integration (optional aggregator: tests/test_all_integration.zig) --

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
        // Give integration tests access to the same named modules.
        integration_mod.addImport("glfw", glfw_mod);
        integration_mod.addImport("vulkan", vk_mod);
        integration_mod.addImport("openxr", xr_mod);
        integration_mod.addImport("graphics_context", graphics_context_mod);
        integration_mod.addImport("swapchain", swapchain_mod);
        integration_mod.addImport("vertex", vertex_mod);

        const integration_tests = b.addTest(.{ .root_module = integration_mod });
        const run_integration = b.addRunArtifact(integration_tests);
        integration_step.dependOn(&run_integration.step);
    }

    // --- E2E (optional aggregator: tests/test_all_e2e.zig) -----------------

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

        const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
        const run_e2e = b.addRunArtifact(e2e_tests);
        e2e_step.dependOn(&run_e2e.step);
    }

    // --- Aggregates --------------------------------------------------------

    const test_all_step = b.step(
        "test-all",
        "Build vrgame and run unit + integration + e2e tests",
    );
    // Make sure the game still builds as part of the pipeline.
    test_all_step.dependOn(b.getInstallStep());
    test_all_step.dependOn(unit_step);
    test_all_step.dependOn(integration_step);
    test_all_step.dependOn(e2e_step);

    // Alias: `zig build test` == `zig build test-all`.
    const test_step = b.step("test", "Alias for test-all");
    test_step.dependOn(test_all_step);

    // Default: `zig build` runs the full suite.
    b.default_step = test_all_step;
}
