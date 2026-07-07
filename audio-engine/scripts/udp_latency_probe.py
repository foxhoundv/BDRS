#!/usr/bin/env python3
import argparse
import socket
import struct
import time
from collections import defaultdict


def percentile(sorted_values, p):
    if not sorted_values:
        return 0.0
    idx = int((len(sorted_values) - 1) * p)
    return sorted_values[idx]


def main():
    parser = argparse.ArgumentParser(description="Probe BDRS UDP packet latency from packet timestamp.")
    parser.add_argument("--bind-ip", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=50000)
    parser.add_argument("--duration-secs", type=int, default=120)
    parser.add_argument("--target-p95-ms", type=float, default=40.0)
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind_ip, args.port))
    sock.settimeout(0.5)

    start = time.time()
    packets = 0
    bad_packets = 0
    latencies_by_stream = defaultdict(list)

    while time.time() - start < args.duration_secs:
        try:
            data, _ = sock.recvfrom(65535)
        except socket.timeout:
            continue

        if len(data) < 33 or data[:4] != b"BDRS":
            bad_packets += 1
            continue

        stream_id = struct.unpack(">H", data[8:10])[0]
        timestamp_micros = struct.unpack(">Q", data[21:29])[0]
        now_micros = int(time.time() * 1_000_000)
        latency_ms = (now_micros - timestamp_micros) / 1000.0
        latencies_by_stream[stream_id].append(latency_ms)
        packets += 1

    sock.close()

    all_latencies = []
    for values in latencies_by_stream.values():
        all_latencies.extend(values)

    if not all_latencies:
        print("LATENCY_RESULT status=error reason=no_packets")
        raise SystemExit(2)

    all_latencies.sort()
    p50 = percentile(all_latencies, 0.50)
    p95 = percentile(all_latencies, 0.95)
    p99 = percentile(all_latencies, 0.99)
    min_v = all_latencies[0]
    max_v = all_latencies[-1]

    status = "pass" if p95 <= args.target_p95_ms else "fail"
    print(
        "LATENCY_RESULT status={} packets={} bad_packets={} streams={} min_ms={:.3f} p50_ms={:.3f} p95_ms={:.3f} p99_ms={:.3f} max_ms={:.3f} target_p95_ms={:.3f}".format(
            status,
            packets,
            bad_packets,
            len(latencies_by_stream),
            min_v,
            p50,
            p95,
            p99,
            max_v,
            args.target_p95_ms,
        )
    )


if __name__ == "__main__":
    main()
