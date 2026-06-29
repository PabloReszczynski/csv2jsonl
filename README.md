# CSV to JSONL tool

Transform a CSV document into JSON Lines.

### Usage

```bash
cat myfile.csv | csv2jsonl > result.jsonl
```

### Library
This package is also provided as a Zig 0.16.0-compatible library with the function `stream_csv_to_jsonl(allocator: std.mem.Allocator, options: Options, reader: *std.Io.Reader, writer: *std.Io.Writer) !void;`

The API is in alpha and subject to change.
It doesn't use any external libraries and I plan to keep it that way.

### Developing and Contributing
Build with `zig build`. There are no tests yet.

I'm not accepting any issues or pull requests that are LLM-generated.
