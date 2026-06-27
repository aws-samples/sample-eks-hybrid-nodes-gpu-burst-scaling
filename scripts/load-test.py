#!/usr/bin/env python3
# =============================================================================
# load-test.py — Multi-phase load test for vLLM burst scaling demonstration
#
# Purpose:
#   Drives a multi-phase workload (warmup -> ramp-up -> sustained -> cooldown)
#   against a vLLM OpenAI-compatible API to demonstrate the hybrid burst-scaling
#   lifecycle: hybrid pod saturation, KEDA trigger activation, Karpenter node
#   provisioning, burst pod readiness, and scale-to-zero on cooldown.
#
# Environment Variables:
#   (None — all configuration via CLI arguments)
#
# Dependencies:
#   pip install aiohttp
#
# Usage:
#   python scripts/load-test.py --endpoint http://localhost:8000
#   python scripts/load-test.py --endpoint http://10.100.0.137:8000 --concurrency 30
#   python scripts/load-test.py --endpoint http://localhost:8000 --duration 60
# =============================================================================
"""
Load test script for vLLM OpenAI-compatible API.

Drives a multi-phase workload (warmup -> ramp-up -> sustained -> cooldown)
to demonstrate the hybrid burst-scaling lifecycle: hybrid pod saturation,
KEDA trigger activation, Karpenter node provisioning, burst pod readiness,
and scale-to-zero on cooldown.

Usage:
    pip install aiohttp
    python scripts/load-test.py --endpoint http://localhost:8000

Metrics are printed every 10s: req/s, TTFT P95, E2E latency P95, error rate.
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import statistics
import time
from dataclasses import dataclass, field
from typing import List, Optional

import aiohttp

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("load-test")


@dataclass
class Sample:
    """A single request observation."""
    ttft: Optional[float]   # seconds to first token
    e2e: Optional[float]    # total request seconds
    ok: bool
    ts: float = field(default_factory=time.time)


@dataclass
class Phase:
    name: str
    duration: int            # seconds
    start_concurrency: int
    end_concurrency: int     # equals start for non-ramp phases


def build_payload(prompt_tokens: int, max_tokens: int) -> dict:
    """Build an OpenAI-compatible chat completion payload with streaming."""
    # Each "token" approximated as a 4-char word in the prompt body.
    body = " ".join(["hello"] * prompt_tokens)
    return {
        "model": "Qwen2.5-1.5B-Instruct",
        "messages": [{"role": "user", "content": body}],
        "max_tokens": max_tokens,
        "temperature": 0.7,
        "stream": True,
    }


async def issue_request(
    session: aiohttp.ClientSession, endpoint: str, payload: dict
) -> Sample:
    """Send one streaming request and capture TTFT and end-to-end latency."""
    start = time.perf_counter()
    ttft: Optional[float] = None
    try:
        async with session.post(
            f"{endpoint}/v1/chat/completions",
            json=payload,
            timeout=aiohttp.ClientTimeout(total=120),
        ) as resp:
            if resp.status != 200:
                return Sample(ttft=None, e2e=None, ok=False)
            async for chunk in resp.content.iter_any():
                if ttft is None and chunk:
                    ttft = time.perf_counter() - start
            e2e = time.perf_counter() - start
            return Sample(ttft=ttft, e2e=e2e, ok=True)
    except (aiohttp.ClientError, asyncio.TimeoutError) as exc:
        log.debug("request failed: %s", exc)
        return Sample(ttft=None, e2e=None, ok=False)


async def worker(
    session: aiohttp.ClientSession,
    endpoint: str,
    payload: dict,
    samples: List[Sample],
    stop_evt: asyncio.Event,
) -> None:
    """Continuously issue requests until the stop event is set."""
    while not stop_evt.is_set():
        sample = await issue_request(session, endpoint, payload)
        samples.append(sample)


def percentile(values: List[float], pct: float) -> float:
    if not values:
        return 0.0
    if len(values) == 1:
        return values[0]
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round(pct / 100 * (len(s) - 1)))))
    return s[k]


def report(samples: List[Sample], window_s: int = 10) -> None:
    """Print metrics for the most recent `window_s` window."""
    cutoff = time.time() - window_s
    recent = [s for s in samples if s.ts >= cutoff]
    total = len(recent)
    if total == 0:
        log.info("no requests in last %ds", window_s)
        return
    errs = sum(1 for s in recent if not s.ok)
    ok_samples = [s for s in recent if s.ok]
    ttfts = [s.ttft for s in ok_samples if s.ttft is not None]
    e2es = [s.e2e for s in ok_samples if s.e2e is not None]
    log.info(
        "rps=%.2f ttft_p95=%.3fs e2e_p95=%.3fs err_rate=%.2f%% n=%d",
        total / window_s,
        percentile(ttfts, 95),
        percentile(e2es, 95),
        100 * errs / total,
        total,
    )


async def run_phase(
    phase: Phase,
    session: aiohttp.ClientSession,
    endpoint: str,
    payload: dict,
    samples: List[Sample],
) -> None:
    """Run one phase, ramping concurrency linearly from start to end."""
    log.info(
        "=== phase=%s duration=%ds concurrency=%d->%d ===",
        phase.name, phase.duration, phase.start_concurrency, phase.end_concurrency,
    )
    workers: List[asyncio.Task] = []
    stop_evt = asyncio.Event()
    start = time.time()
    last_report = start
    current = 0

    while time.time() - start < phase.duration:
        elapsed = time.time() - start
        progress = elapsed / phase.duration if phase.duration > 0 else 1.0
        target = int(
            phase.start_concurrency
            + (phase.end_concurrency - phase.start_concurrency) * progress
        )
        # Spawn workers up to target.
        while current < target:
            workers.append(
                asyncio.create_task(
                    worker(session, endpoint, payload, samples, stop_evt)
                )
            )
            current += 1
        # Periodic metrics.
        if time.time() - last_report >= 10:
            report(samples)
            last_report = time.time()
        await asyncio.sleep(0.5)

    stop_evt.set()
    await asyncio.gather(*workers, return_exceptions=True)
    report(samples)


async def cooldown(duration: int, samples: List[Sample]) -> None:
    """Observe metrics with no traffic to watch scale-to-zero."""
    log.info("=== phase=cooldown duration=%ds (observing only) ===", duration)
    end = time.time() + duration
    while time.time() < end:
        await asyncio.sleep(10)
        report(samples)


async def main_async(args: argparse.Namespace) -> None:
    payload = build_payload(args.prompt_tokens, args.max_tokens)
    samples: List[Sample] = []
    connector = aiohttp.TCPConnector(limit=args.concurrency * 2)
    async with aiohttp.ClientSession(connector=connector) as session:
        if args.duration:
            phase = Phase("custom", args.duration, args.concurrency, args.concurrency)
            await run_phase(phase, session, args.endpoint, payload, samples)
            return
        phases = [
            Phase("warmup", 30, 1, 1),
            Phase("ramp-up", 120, 1, 20),
            Phase("sustained", 300, 20, 20),
        ]
        for p in phases:
            await run_phase(p, session, args.endpoint, payload, samples)
        await cooldown(600, samples)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--endpoint", default="http://localhost:8000",
                   help="vLLM OpenAI-compatible base URL")
    p.add_argument("--concurrency", type=int, default=20,
                   help="Concurrent workers (used only with --duration)")
    p.add_argument("--duration", type=int, default=0,
                   help="If >0, run a single custom phase for this many seconds "
                        "instead of the default warmup/ramp/sustained/cooldown")
    p.add_argument("--prompt-tokens", type=int, default=128,
                   help="Approximate prompt size in tokens")
    p.add_argument("--max-tokens", type=int, default=128,
                   help="Max tokens to generate per request")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    log.info("target=%s concurrency=%d prompt=%d max=%d",
             args.endpoint, args.concurrency, args.prompt_tokens, args.max_tokens)
    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        log.warning("interrupted by user")


if __name__ == "__main__":
    main()
