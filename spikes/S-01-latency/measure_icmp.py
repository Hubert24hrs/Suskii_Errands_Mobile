"""S-01 (partial) — ICMP RTT from this machine to candidate cloud regions.

Why ICMP and not TCP: in this environment TCP connects are terminated locally (every
region returned the same ~131 ms floor, including Virginia and Cape Town, which is
physically impossible). ICMP is not intercepted and differentiates correctly, so it is
the instrument here.

What this measures: network path RTT from ONE vantage point (this machine, one access
network) to a regional endpoint. It is not Supabase RPC latency and not a substitute for
probes in Lagos, Nairobi and Johannesburg on mobile networks.

Read min, not average: min is the uncongested path; avg/max on this link carry access
network jitter.

Usage: python measure_icmp.py [count]
"""

import json
import re
import subprocess
import sys
import time

COUNT = int(sys.argv[1]) if len(sys.argv) > 1 else 12

TARGETS = [
    ("anycast", "Cloudflare 1.1.1.1 (nearest edge)", "1.1.1.1"),
    ("anycast", "Google DNS 8.8.8.8 (nearest edge)", "8.8.8.8"),
    ("aws", "eu-west-2 London", "dynamodb.eu-west-2.amazonaws.com"),
    ("aws", "eu-west-3 Paris", "dynamodb.eu-west-3.amazonaws.com"),
    ("aws", "eu-west-1 Ireland", "dynamodb.eu-west-1.amazonaws.com"),
    ("aws", "eu-central-1 Frankfurt", "dynamodb.eu-central-1.amazonaws.com"),
    ("aws", "eu-north-1 Stockholm", "dynamodb.eu-north-1.amazonaws.com"),
    ("aws", "ap-south-1 Mumbai", "dynamodb.ap-south-1.amazonaws.com"),
    ("aws", "af-south-1 Cape Town", "dynamodb.af-south-1.amazonaws.com"),
    ("aws", "us-east-1 N. Virginia", "dynamodb.us-east-1.amazonaws.com"),
    ("gcp", "GCP europe-west2 (GFE)", "europe-west2-aiplatform.googleapis.com"),
    ("gcp", "GCP africa-south1 (GFE)", "africa-south1-aiplatform.googleapis.com"),
]

# Windows ping summary, e.g. "Minimum = 150ms, Maximum = 369ms, Average = 268ms"
SUMMARY = re.compile(r"Minimum = (\d+)ms, Maximum = (\d+)ms, Average = (\d+)ms")
LOSS = re.compile(r"\((\d+)% loss\)")
PER_REPLY = re.compile(r"time[=<](\d+)ms")


def ping(host, count):
    try:
        out = subprocess.run(
            ["ping", "-n", str(count), host],
            capture_output=True, text=True, timeout=count * 3 + 20,
        ).stdout
    except (subprocess.TimeoutExpired, OSError) as exc:
        return {"error": str(exc)}
    row = {"replies": [int(m) for m in PER_REPLY.findall(out)]}
    m = SUMMARY.search(out)
    if m:
        row.update(min=int(m.group(1)), max=int(m.group(2)), avg=int(m.group(3)))
    m = LOSS.search(out)
    if m:
        row["loss_pct"] = int(m.group(1))
    if "min" not in row:
        row["error"] = "no ICMP summary (blocked or unreachable)"
    return row


def main():
    results = []
    print(f"{'target':34s} {'min':>6s} {'avg':>6s} {'max':>6s} {'loss':>6s}")
    for group, label, host in TARGETS:
        row = ping(host, COUNT)
        row.update(group=group, label=label, host=host)
        results.append(row)
        if "error" in row:
            print(f"{label:34s} ERROR {row['error']}")
        else:
            print(f"{label:34s} {row['min']:6d} {row['avg']:6d} {row['max']:6d} {row['loss_pct']:5d}%")
        time.sleep(0.5)

    ok = [r for r in results if "min" in r and r["group"] in ("aws", "gcp")]
    floor = min((r["min"] for r in results if r["group"] == "anycast" and "min" in r), default=None)
    out = {
        "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "count_per_target": COUNT,
        "access_network_floor_ms": floor,
        "method": "ICMP; min RTT is the signal. TCP is proxied in this environment.",
        "results": results,
    }
    with open("results-icmp.json", "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2)

    if floor is not None:
        print(f"\nNearest-edge floor (access network): {floor} ms")
        print("Long-haul cost above that floor:")
        for r in sorted(ok, key=lambda r: r["min"]):
            print(f"  {r['label']:34s} {r['min']:4d} ms  (+{r['min'] - floor:4d} ms)")
    print("\nwrote results-icmp.json")


if __name__ == "__main__":
    main()
