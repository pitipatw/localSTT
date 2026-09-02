#!/usr/bin/env python3
"""Summarise ~/.local/share/dictate/log.jsonl: hook latency, LLM usage, guard hits.

Note: latency_ms here is polish.py's own wall time (hook entry -> exit). Release-to-paste
latency = ASR time (see `journalctl --user -u voxtype`) + this number + paste delay.
Targets from the handoff §7.3: LLM path median < 1500 ms total, ASR-only median < 400 ms.
"""

import json
import statistics
import sys
from collections import Counter
from pathlib import Path


def pct(values, p):
    if not values:
        return float("nan")
    s = sorted(values)
    return s[min(len(s) - 1, int(round(p / 100 * (len(s) - 1))))]


def main(path):
    entries = [json.loads(l) for l in Path(path).read_text(encoding="utf-8").splitlines() if l.strip()]
    if not entries:
        print("log is empty")
        return
    llm = [e["latency_ms"] for e in entries if e.get("llm_used")]
    no_llm = [e["latency_ms"] for e in entries if not e.get("llm_used")]
    print(f"entries: {len(entries)}   llm_used: {len(llm)}   skipped: {len(no_llm)}")
    for label, xs in (("LLM path hook latency", llm), ("non-LLM hook latency", no_llm)):
        if xs:
            print(f"{label:24s} median {statistics.median(xs):6.0f} ms   p95 {pct(xs, 95):6.0f} ms   max {max(xs):6.0f} ms")
    reasons = Counter(e.get("reason", "?").split(":")[0] for e in entries)
    print("reasons:", ", ".join(f"{k}={v}" for k, v in reasons.most_common()))
    changed = sum(1 for e in entries if e.get("final") != e.get("corrected"))
    print(f"LLM changed text in {changed}/{len(entries)} dictations")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else Path("~/.local/share/dictate/log.jsonl").expanduser())
