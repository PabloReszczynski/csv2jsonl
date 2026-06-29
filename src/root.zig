// Copyright © Pablo Reszczynski
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

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
    header: ?[][]const u8 = null,
};

pub const Error = error{
    /// A data row has a different number of fields than the header row.
    UnmatchedHeaderAndRowColumns,
};

/// Finds the first position of any of the values provided in the buffer.
///
/// Similar to `indexOfAny` but uses SIMD to find values in parallel.
fn vIndexOfAny(buffer: []const u8, values: []const u8) ?usize {
    const vec_len = 16;
    const Vec = @Vector(vec_len, u8);
    var i: usize = 0;
    while (i + vec_len <= buffer.len) : (i += vec_len) {
        const chunk: Vec = buffer[i..][0..vec_len].*;
        var bitmask: u16 = 0;
        for (values) |val| {
            const is_equal = chunk == @as(Vec, @splat(val));
            bitmask |= @as(u16, @bitCast(is_equal));
        }
        if (bitmask != 0) return i + @ctz(bitmask);
    }
    while (i < buffer.len) : (i += 1) {
        for (values) |val| if (buffer[i] == val) return i;
    }
    return null;
}

fn outputSpecialEscape(c: u8, writer: *std.Io.Writer) !void {
    switch (c) {
        '\\' => try writer.writeAll("\\\\"),
        '\"' => try writer.writeAll("\\\""),
        0x08 => try writer.writeAll("\\b"),
        0x0C => try writer.writeAll("\\f"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => {
            try writer.writeAll("\\u00");
            const hex = "0123456789abcdef";
            try writer.writeByte(hex[(c >> 4) & 0xF]);
            try writer.writeByte(hex[c & 0xF]);
        },
    }
}

fn needsEscape(c: u8) bool {
    return c < 0x20 or c == '"' or c == '\\';
}

/// SIMD-Powered JSON string serializer
///
/// Write `s` as a JSON string literal with surrounding quotes (`"`).
/// Handles escaping and control characters.
fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');

    // apple m3 chip NEON register are 16 bytes, so we can use 16-length vector
    // and use 1 register per operation
    // TODO: Tune this value or allow users to set it, or check user arch.
    const vec_len = 16;
    const Vec = @Vector(vec_len, u8);
    var i: usize = 0;
    var start: usize = 0;
    // use simd to find positions where special characters lie, then use a bitmask
    // to replace them with their escaped versions
    while (i + vec_len <= s.len) {
        const chunk = s[i..][0..vec_len].*;
        const is_control_char = chunk < @as(Vec, @splat(0x20));
        const is_quote = chunk == @as(Vec, @splat('"'));
        const is_backslash = chunk == @as(Vec, @splat('\\'));
        const bitmask: u16 = @as(u16, @bitCast(is_control_char)) | @as(u16, @bitCast(is_quote)) | @as(u16, @bitCast(is_backslash));
        if (bitmask != 0) {
            const offset = @ctz(bitmask);
            try writer.writeAll(s[start .. i + offset]);
            try outputSpecialEscape(s[i + offset], writer);
            i += offset + 1;
            start = i;
        } else {
            i += vec_len;
        }
    }
    // Use manual (byte by byte) serialization for the rest of the characters
    while (i < s.len) : (i += 1) {
        if (needsEscape(s[i])) {
            try writer.writeAll(s[start..i]);
            try outputSpecialEscape(s[i], writer);
            start = i + 1;
        }
    }
    try writer.writeAll(s[start..]);
    try writer.writeByte('"');
}

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
                if (vIndexOfAny(buffer, active_special)) |pos| {
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
        // we use our own handrolled JSON serializer that uses SIMD to optimize
        // writing strings by replacing special characters in parallel
        // (since we only produce objects of type string -> string)
        try writer.writeByte('{');
        for (header.?, cells.items, 0..) |k, v, idx| {
            if (idx != 0) try writer.writeByte(',');
            try writeJsonString(writer, k);
            try writer.writeByte(':');
            try writeJsonString(writer, v);
        }
        try writer.writeAll("}\n");
    }
}
