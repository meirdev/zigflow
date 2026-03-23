# zigflow

Zero dependencies IPFIX (RFC 7011) collector written in Zig.

## Build

```
make build
```

## Usage

```
./zigflow [options]
```

### Options

| Flag           | Description                                         | Default        |
| -------------- | --------------------------------------------------- | -------------- |
| `-p`, `--port` | UDP port to listen on                               | 4739           |
| `-b`, `--bind` | Bind address                                        | 0.0.0.0        |
| `-j`, `--json` | Output in JSON format (one line per IPFIX message)  | off (raw text) |
| `--proto`      | Output in Protobuf binary format (per `flow.proto`) | off (raw text) |

### Protobuf Example

When using `--proto`, zigflow emits each flow as a length-delimited Protobuf message
defined in [flow.proto](flow.proto).

```bash
./zigflow --proto | uv run decode_proto.py
```
