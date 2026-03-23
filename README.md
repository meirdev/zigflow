# zigflow

Zero dependencies IPFIX (RFC 7011) collector written in Zig.

## Build

```
zig build-exe ipfix.zig
```

## Usage

```
./ipfix [options]
```

### Options

| Flag           | Description                                        | Default        |
| -------------- | -------------------------------------------------- | -------------- |
| `-p`, `--port` | UDP port to listen on                              | 4739           |
| `-b`, `--bind` | Bind address                                       | 0.0.0.0        |
| `-j`, `--json` | Output in JSON format (one line per IPFIX message) | off (raw text) |
