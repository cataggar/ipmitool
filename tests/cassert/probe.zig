const cassert = @import("cassert");
const options = @import("test_options");

pub fn main() void {
    const site: cassert.Site = .{
        .file = "assertion.c",
        .line = 42,
        .func = "fixture",
        .expr = if (options.mode == .long) "x" ** 1024 else "expression",
    };
    if (options.mode == .unreachable_branch) cassert.unreachableBranch(site);
    cassert.expect(options.mode == .pass, site);
}
