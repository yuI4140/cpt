const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
       const exe = b.addExecutable(.{
        .name = "cpt",
        .root_module = b.createModule(.{
               .root_source_file = b.path("src/cpt.zig"),
               .target = target,
            .optimize = optimize,
           }),
    });
    exe.addIncludePath(.{ .cwd_relative = "thirdparty/" });
    exe.addLibraryPath(.{.cwd_relative = "thirdparty/lib"});
    exe.linkSystemLibrary("nob");
    exe.linkLibC();
    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
}
