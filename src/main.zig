const std = @import("std");

const csv2jsonl = @import("csv2jsonl");

const use_debug_alloc = std.debug.runtime_safety;
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main(init: std.process.Init) !void {
    const allocator = if (use_debug_alloc) debug_allocator.allocator() else std.heap.smp_allocator;
    defer {
        if (use_debug_alloc) {
            const check = debug_allocator.deinit();
            if (check == .leak) {
                @panic("Leaking memory");
            }
        }
    }

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    var options: csv2jsonl.Options = .{};

    // parse arguments
    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var help_buffer: [1024]u8 = undefined;
            var help_writer = std.Io.File.stdout().writer(init.io, &help_buffer);
            const hw = &help_writer.interface;
            try hw.writeAll(
                \\Usage: csv2jsonl [OPTIONS]
                \\
                \\Read CSV from stdin, write one JSON object per line to stdout.
                \\UTF-8 BOM is stripped automatically if present.
                \\
                \\Options:
                \\  -d, --delimiter CHAR   Field delimiter (default: ,)
                \\  -q, --quote CHAR       Quote character (default: ")
                \\  -e, --escape CHAR      Escape character (default: \)
                \\  -h, --help             Show this help
                \\
                \\Examples:
                \\  cat data.csv | csv2jsonl
                \\  cat data.tsv | csv2jsonl -d $'\t'
                \\
            );
            try hw.flush();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delimiter")) {
            if (i + 1 >= args.len) {
                std.debug.print("'delimiter' expectes an argument\n", .{});
                std.process.exit(1);
            }
            options.delimiter = args[i + 1][0];
            i += 1;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quote")) {
            if (i + 1 >= args.len) {
                std.debug.print("'quote' expectes an argument\n", .{});
                std.process.exit(1);
            }
            options.quote = args[i + 1][0];
            i += 1;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--escape")) {
            if (i + 1 >= args.len) {
                std.debug.print("'escape' expectes an argument\n", .{});
                std.process.exit(1);
            }
            options.escape = args[i + 1][0];
            i += 1;
        } else {
            std.debug.print("unknown argument '{s}'\n", .{arg});
            std.process.exit(1);
        }
        i += 1;
    }

    var stdin_buffer: [1024 * 64]u8 = undefined;
    var stdout_buffer: [1024 * 64]u8 = undefined;
    var reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    var writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);

    try csv2jsonl.stream_csv_to_jsonl(allocator, options, @constCast(&reader.interface), @constCast(&writer.interface));

    try writer.interface.flush();
}
