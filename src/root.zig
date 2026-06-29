//! CSV to JSON Lines converter.
//!
//! Reads CSV from a `std.Io.Reader` and writes one JSON object per line to a
//! `std.Io.Writer`. The first row is treated as the header and becomes the
//! key names in each output object. UTF-8 BOM is stripped automatically.

const std = @import("std");

/// Controls CSV parsing behaviour. All fields have RFC 4180-compatible defaults.
pub const Options = struct {
    /// Byte that separates fields within a row.
    delimiter: u8 = ',',
    /// Byte used to quote fields that contain special characters.
    quote: u8 = '"',
    /// Byte that escapes the following character inside a field.
    escape: u8 = '\\',
    /// Provide optional header
    header: ?[][]const u8 = null
};

pub const Error = error{
    /// A data row has a different number of fields than the header row.
    UnmatchedHeaderAndRowColumns,
};

/// Read CSV from `reader` and write one JSON object per line to `writer`.
///
/// If a `header` is not passed to `options`, the first non-empty row is used as
/// the header; every subsequent row is serialised as
/// `{"col1":"val1","col2":"val2",...}\n`. Blank lines are skipped. `allocator`
/// is used for internal bookkeeping; the caller is responsible for flushing
/// `writer` after this function returns.
pub fn stream_csv_to_jsonl(allocator: std.mem.Allocator, options: Options, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const row_allocator = arena.allocator();
    const special = [_]u8{ options.delimiter, options.quote, options.escape, '\n', '\r' };

    // peek BOM and verify magic number
    const first_bytes = reader.peekArray(3) catch |err| switch (err) {
        error.EndOfStream => {
            // No input
            return;
        },
        else => return err,
    };
    if (std.mem.eql(u8, first_bytes, "\xEF\xBB\xBF")) {
        _ = try reader.take(3);
    }

    // start reading CSV
    var end_of_stream = false;
    var header = options.header;
    defer {
        if (header) |h| {
            for (h) |col| allocator.free(col);
            allocator.free(h);
        }
    }
    var sb: std.ArrayList(u8) = .empty;
    defer sb.deinit(allocator);

    var cells: std.ArrayList([]const u8) = .empty;
    defer cells.deinit(allocator);

    while (!end_of_stream) {
        // Read line by line
        var end_of_line = false;
        cells.clearRetainingCapacity();
        while (!end_of_line and !end_of_stream) {
            // Read cell by cell
            var in_quote = false;
            var last_byte: ?u8 = null;

            if (cells.items.len == 0) {
                // peek first byte of line
                const peek = reader.peekByte() catch |err| switch (err) {
                    // if EOF, end gracefully
                    error.EndOfStream => {
                        end_of_stream = true;
                        break;
                    },
                    else => return err,
                };

                // if first line of row is '\n' or '\r\n', skip the line
                if (peek == '\n') {
                    _ = try reader.takeByte();
                    continue;
                } else if (peek == '\r') {
                    // consume before peeking again
                    _ = try reader.takeByte();
                    const next_byte = try reader.peekByte();
                    if (next_byte == '\n') {
                        _ = try reader.takeByte();
                        continue;
                    }
                }
            }

            sb.clearRetainingCapacity();
            while (true) {
                // ensure at least 1 byte is buffered; handles refill and EOF
                _ = reader.peek(1) catch |err| switch (err) {
                    error.EndOfStream => {
                        if (in_quote) @panic("eof while reading inside quotes");
                        end_of_stream = true;
                        break;
                    },
                    else => return err,
                };
                const buffer = reader.buffer[reader.seek..reader.end];
                const active_special = if (in_quote) &[_]u8{ options.quote, options.escape } else &special;

                // find next special character using simd
                if (std.mem.indexOfAny(u8, buffer, active_special)) |pos| {
                    const byte = buffer[pos];
                    // append all the characters before the special char
                    try sb.appendSlice(allocator, buffer[0..pos]);
                    _ = try reader.take(pos + 1); // consume prefix + special
                    if (byte == options.quote) {
                        in_quote = !in_quote;
                    } else if (byte == '\r') {
                        // if in quote or escaped, just write the character
                        if (last_byte == options.escape or in_quote) {
                            try sb.append(allocator, byte);
                        } else {
                            // peek next character. If it is '\n', skip both
                            // and register the new line
                            const next_byte = try reader.peekByte();
                            if (next_byte == '\n') _ = try reader.takeByte();
                            end_of_line = true;
                            break;
                        }
                    } else if (byte == '\n') {
                        if (last_byte == options.escape or in_quote) {
                            try sb.append(allocator, byte);
                        } else {
                            // finish reading line
                            end_of_line = true;
                            break;
                        }
                    } else if (byte == options.delimiter) {
                        if (last_byte == options.escape or in_quote) {
                            try sb.append(allocator, byte);
                        } else {
                            // finish reading cell
                            break;
                        }
                    } else if (byte == options.escape) {
                        // skip this byte
                    }
                    last_byte = byte;
                } else {
                    // no special byte found, append entire buffer
                    try sb.appendSlice(allocator, buffer);
                    _ = try reader.take(buffer.len);
                    last_byte = buffer[buffer.len - 1];
                }
            }
            const cell = try row_allocator.dupe(u8, sb.items);
            try cells.append(allocator, cell);
        }
        // skip empty lines
        if (cells.items.len == 0) {
            cells.clearRetainingCapacity();
            continue;
        }

        // If header is null, this row is the header row
        // copy each cell to the header
        if (header == null) {
            for (cells.items) |*cell| {
                cell.* = try allocator.dupe(u8, cell.*);
            }
            header = try cells.toOwnedSlice(allocator);
            continue;
        }

        // If not, then treat cells_slice as row
        defer {
            cells.clearRetainingCapacity();
            // Resets the arena once per row
            _ = arena.reset(.retain_capacity);
        }

        // check that header length and cell length are the same
        if (cells.items.len != header.?.len) {
            return Error.UnmatchedHeaderAndRowColumns;
        }

        // serialize to json
        var ws: std.json.Stringify = .{
            .writer = writer,
        };
        try ws.beginObject();
        for (header.?, cells.items) |k, v| {
            try ws.objectField(k);
            try ws.write(v);
        }
        try ws.endObject();
        try writer.writeByte('\n');
    }
}
