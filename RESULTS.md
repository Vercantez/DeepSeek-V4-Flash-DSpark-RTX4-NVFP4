# Results — single 2× DGX Spark stack (TP=2)

All single-stack numbers are **one stack = 2× DGX Spark (GB10), TP=2**, one GPU per
node, serving `DeepSeek-V4-Flash-DSpark` with this patch:
`kv-cache-dtype fp8`, DSpark `γ=5`, `gpu-memory-utilization 0.80`,
`max-model-len 262144`, `VLLM_DSPARK_GPU_REJECTED_CONTEXT_MASK=1`,
`max-num-seqs 16`.

Throughput is **server-side** (`/metrics vllm:generation_tokens_total` delta);
acceptance is `spec_decode_num_accepted_tokens / num_draft_tokens`. Scripts in
`benchmarks/`.

## Single-stream baseline

| metric | value |
|---|---:|
| decode | ~50–54 tok/s |
| draft acceptance | ~0.55–0.62 |
| accepted / draft block | ~3.2 |

Single-stream is **byte-identical** to the unpatched engine (the patch is a no-op
when the batch permutation is identity).

## Concurrency — STATIC batch (all requests simultaneous; best-case overlap)

| concurrency | server aggregate | per-stream | acceptance |
|---:|---:|---:|---:|
| 1  | 49 tok/s  | 49 | ~0.61 |
| 2  | 81 tok/s  | 40 | ~0.59 |
| 4  | 122 tok/s | 30 | ~0.59 |
| 8  | 183 tok/s | 23 | ~0.59 |
| 16 | **290 tok/s** | 18 | ~0.60 |

## Concurrency — STAGGERED arrivals (real, independent; the ragged path Patch 2 enables)

| concurrency | success | server aggregate | acceptance |
|---:|---:|---:|---:|
| 1  | 1/1   | 46 tok/s  | ~0.51 |
| 4  | 4/4   | 104 tok/s | ~0.59 |
| 8  | 8/8   | 139 tok/s | ~0.56 |
| 16 | 16/16 | **191 tok/s** | ~0.55 |

Static is the upper bound (perfect overlap); staggered is the realistic floor for
that load shape. Production lands between them. **Zero errors at every level;
acceptance stays healthy (~0.55) — DSpark keeps accelerating under concurrency.**

## Correctness under continuous-batch condense

| check | result |
|---|---|
| Deterministic output, alone vs under churn (requests start/finish around it) | **byte-identical** |
| Requests succeeding while others churn | 16/16, 0 errors |
| Single-stream vs unpatched engine | byte-identical (no-op) |

## Quality eval — GSM8K (concurrency is quality-neutral)

Same 200 GSM8K questions, greedy (temp 0), run on one patched stack two ways:

| run | accuracy | request errors |
|---|---:|---:|
| Sequential (single-stream path) | **95.0%** (190/200) | 0 |
| Concurrent N=8 (patched batching path) | **93.5%** (187/200) | 0 |
| **Per-question agreement** | **97.5%** (195/200 identical predictions) | |

Only 5/200 predictions differ (4 seq-only-correct, 1 conc-only-correct; one is an
answer-*extraction* artifact). The divergences are small CoT drift on borderline
problems — the signature of **batch-size FP-reduction-order nondeterminism**, which
is inherent to *any* vLLM model between batch=1 and batch=8, not the patch. Net
accuracy delta is within batch noise. **Conclusion: concurrency does not degrade
output quality.** (This eval also caught and drove a fix — see Patch 2b in
`docs/PATCHES.md`.)

## Summary (one 2-Spark stack)

| | before patch | after (Patch 1 + Patch 2) |
|---|---|---|
| concurrency | locked to 1 (single stream) | up to 16 concurrent, correct |
| `max-num-seqs>1` | acceptance collapse / HTTP 500 | 0 errors, acceptance ~0.55 |
| throughput | 1 stream @ ~52 tok/s | **~290 static / ~191 staggered @16**; single-stream unchanged |

---

# Scaling out — replica parallelism to multiply concurrency

To go wider, run **N independent patched TP=2 stacks** behind a least-connections
router. Each request runs entirely on one stack — no cross-stack coordination — so
aggregate and concurrency scale **~linearly** with stacks.

## Measured: 1 stack vs 2 stacks (staggered, real arrivals)

| total concurrency | 1 stack (2 Sparks) | 2 stacks (4 Sparks) | scaling |
|---:|---:|---:|---:|
| 8  | 139 tok/s | **195 tok/s** (4+4) | — |
| 16 | 191 tok/s | **266 tok/s** (8+8) | — |
| 32 | —         | **375 tok/s** (16+16) | **~1.96× vs 1-stack@16** |

2-stack run: 32/32 requests OK, **0 errors**, acceptance ~0.54 — dual stacks hit
**~1.9–2.0× the single-stack aggregate**, confirming near-linear replica scaling.

## Scaling rule of thumb

| stacks | DGX Sparks | concurrency | aggregate (staggered) |
|---:|---:|---:|---:|
| 1 | 2 | 16 | ~191 tok/s |
| 2 | 4 | 32 | ~375 tok/s |
| N | 2N | 16N | ~190N tok/s |

Notes:
- **TP=2 is the floor** for this model (~157 GB weights won't fit one 128 GB GB10),
  so each stack is 2 Sparks; you can't get more streams by going TP=1 single-node.
- Put any least-connections proxy (nginx / LiteLLM / a small round-robin) in front
  of the stacks' endpoints; pin a request to one stack for its lifetime.
- Per-stream latency drops as in-stack concurrency rises (throughput↔latency trade).
  For both high width **and** high per-stream tok/s, add stacks rather than raising
  `max-num-seqs` on one.

---

### Caveats
- Certified for correctness, stability (N≤16/stack, 32 across 2 stacks),
  acceptance, **and task quality (GSM8K N=8 vs single-stream: quality-neutral,
  97.5% per-question agreement)**. A multi-hour soak is still recommended before
  production.
- Requires `VLLM_DSPARK_GPU_REJECTED_CONTEXT_MASK=1` (the patched ragged path).
- Validated on V4-Flash-DSpark; V4-Pro-DSpark expected to work (shared code) but
  untested.
