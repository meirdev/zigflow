# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "protobuf>=5.29.3",
# ]
# ///
import sys
from datetime import datetime, timezone
from ipaddress import ip_address

from google.protobuf import proto

from flow_pb2 import Flow

while True:
    try:
        flow = proto.parse_length_prefixed(Flow, sys.stdin.buffer)
    except EOFError:
        break
    except Exception as e:
        print(f"Error parsing flow: {e}", file=sys.stderr)
    else:
        time_received = datetime.fromtimestamp(
            flow.time_received_ns / 1e9, timezone.utc
        )

        src_addr = ip_address(flow.src_addr)
        dst_addr = ip_address(flow.dst_addr)
        sampler_address = ip_address(flow.sampler_address)

        print(
            f"{time_received.isoformat()} {src_addr}:{flow.src_port} > {dst_addr}:{flow.dst_port} protocol: {flow.proto} flags: {flow.tcp_flags} packets: {flow.packets} size: {flow.bytes} bytes sample ratio: {flow.sampling_rate} agent: {sampler_address}"
        )
