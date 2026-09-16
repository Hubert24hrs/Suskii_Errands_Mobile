"""S-01 (partial) — network RTT from this machine to candidate cloud regions.

Throwaway spike harness. Measures TCP connect time (one round trip after DNS) to a
regional endpoint in each candidate region, plus one TLS handshake sample.

This is a network-path proxy, NOT Supabase RPC latency: it says nothing about query
time, connection pooling or Realtime. It answers one question only — which region is
closest in network terms from where this machine sits.

Usage: python measure.py [samples]
"""

import json
import socket
import ssl
import statistics
import sys
import time

SAMPLES = int(sys.argv[1]) if len(sys.argv) > 1 else 15
TIMEOUT = 5.0

# AWS regional endpoints (Supabase runs on AWS). dynamodb.<region> is a genuinely
# regional endpoint, so the RTT reflects the path to that region rather than to an edge.
AWS = {
    "eu-west-2 London": "dynamodb.eu-west-2.amazonaws.com",
    "eu-west-3 Paris": "dynamodb.eu-west-3.amazonaws.com",
    "eu-west-1 Ireland": "dynamodb.eu-west-1.amazonaws.com",
    "eu-central-1 Frankfurt": "dynamodb.eu-central-1.amazonaws.com",
    "eu-north-1 Stockholm": "dynamodb.eu-north-1.amazonaws.com",
    "ap-south-1 Mumbai": "dynamodb.ap-south-1.amazonaws.com",
    "af-south-1 Cape Town": "dynamodb.af-south-1.amazonaws.com",
    "us-east-1 N. Virginia": "dynamodb.us-east-1.amazonaws.com",
}

# Google frontends answer close to the client, so these numbers are a floor for the
# Vertex path, not the region's true distance. Recorded for contrast only.
GCP = {
    "GCP europe-west2 (GFE)": "europe-west2-aiplatform.googleapis.com",
    "GCP africa-south1 (GFE)": "africa-south1-aiplatform.googleapis.com",
}

OTHER = {
    "supabase.com (CDN)": "supabase.com",
}


def resolve(host):
    t0 = time.perf_counter()
    try:
        addr = socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
    except OSError as exc:
        return None, None, str(exc)
    return addr, (time.perf_counter() - t0) * 1000, None


def tcp_connect_ms(addr, host):
    t0 = time.perf_counter()
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(TIMEOUT)
    try:
        s.connect((addr, 443))
        return (time.perf_counter() - t0) * 1000
    except OSError:
        return None
    finally:
        s.close()


def tls_handshake_ms(addr, host):
    ctx = ssl.create_default_context()
    t0 = time.perf_counter()
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(TIMEOUT)
    try:
        s.connect((addr, 443))
        with ctx.wrap_socket(s, server_hostname=host):
            return (time.perf_counter() - t0) * 1000
    except OSError:
        return None
    finally:
        try:
            s.close()
        except OSError:
            pass


def pct(values, p):
    if not values:
        return None
    ordered = sorted(values)
    k = min(len(ordered) - 1, int(round((p / 100.0) * (len(ordered) - 1))))
    return ordered[k]


def measure(label, host):
    addr, dns_ms, err = resolve(host)
    if err:
        return {"label": label, "host": host, "error": err}
    rtts = []
    for _ in range(SAMPLES):
        ms = tcp_connect_ms(addr, host)
        if ms is not None:
            rtts.append(ms)
        time.sleep(0.05)
    return {
        "label": label,
        "host": host,
        "ip": addr,
        "dns_ms": round(dns_ms, 1),
        "n": len(rtts),
        "loss": SAMPLES - len(rtts),
        "min": round(min(rtts), 1) if rtts else None,
        "median": round(statistics.median(rtts), 1) if rtts else None,
        "p95": round(pct(rtts, 95), 1) if rtts else None,
        "max": round(max(rtts), 1) if rtts else None,
        "tls_ms": (lambda v: round(v, 1) if v else None)(tls_handshake_ms(addr, host)),
    }


def main():
    results = []
    for group, targets in (("aws", AWS), ("gcp", GCP), ("other", OTHER)):
        for label, host in targets.items():
            row = measure(label, host)
            row["group"] = group
            results.append(row)
            if "error" in row:
                print(f"{label:28s} ERROR {row['error']}")
            else:
                print(
                    f"{label:28s} min {row['min']:7.1f}  med {row['median']:7.1f}  "
                    f"p95 {row['p95']:7.1f}  tls {row['tls_ms'] or -1:7.1f}  loss {row['loss']}/{SAMPLES}"
                )
    out = {
        "samples_per_target": SAMPLES,
        "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "results": results,
    }
    with open("results.json", "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2)
    print("\nwrote results.json")


if __name__ == "__main__":
    main()
