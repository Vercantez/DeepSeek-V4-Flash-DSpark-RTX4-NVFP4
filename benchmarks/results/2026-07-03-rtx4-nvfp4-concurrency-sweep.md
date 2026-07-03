# RTX PRO 6000 x4 NVFP4 DSpark Concurrency Sweep

Runtime:
- Image: `vllm-dspark-runtime:rtx4-nvfp4-port-v3`
- Model: `deepseek-ai/DeepSeek-V4-Flash-DSpark`
- KV cache dtype: `nvfp4_ds_mla`
- Speculative decoding: DSpark, `num_speculative_tokens=5`
- `max_num_seqs=64`
- `max_num_batched_tokens=8192`
- Benchmark: `benchmarks/bench_concurrent.py`, streaming, `max_tokens=256`, best of 2 runs

In-capacity sweep:

| concurrency | aggregate tok/s | per-stream tok/s | acceptance |
| ---: | ---: | ---: | ---: |
| 1 | 304.3 | 304.3 | 0.714 |
| 2 | 511.7 | 255.9 | 0.669 |
| 3 | 586.5 | 195.5 | 0.677 |
| 4 | 726.4 | 181.6 | 0.666 |
| 6 | 923.6 | 153.9 | 0.649 |
| 8 | 1265.5 | 158.2 | 0.699 |
| 12 | 1547.0 | 128.9 | 0.688 |
| 16 | 1691.2 | 105.7 | 0.644 |
| 24 | 2275.3 | 94.8 | 0.669 |
| 32 | 2880.1 | 90.0 | 0.704 |
| 40 | 2876.1 | 71.9 | 0.661 |
| 48 | 3268.7 | 68.1 | 0.686 |
| 56 | 3212.0 | 57.4 | 0.658 |
| 64 | 3341.2 | 52.2 | 0.659 |

Overload sweep:

| concurrency | aggregate tok/s | per-stream tok/s | acceptance |
| ---: | ---: | ---: | ---: |
| 72 | 2737.0 | 38.0 | 0.659 |
| 80 | 2882.9 | 36.0 | 0.665 |
| 96 | 2938.9 | 30.6 | 0.659 |
| 128 | 3105.4 | 24.3 | 0.666 |

Interpretation:
- Best observed throughput was `3341.2 tok/s` at `x64`.
- The practical plateau starts around `x48`; `x64` was slightly higher but with lower per-stream decode.
- Above `x64`, throughput did not improve. Extra client concurrency mostly created queueing behind `max_num_seqs=64`.
- For service testing, `x48` looks like the best balance point in this benchmark: near-peak aggregate throughput with better per-stream rate than `x64`.

Raw logs:
- `raw/granular-concurrency-20260703T012834Z.log`
- `raw/overload-concurrency-20260703T012958Z.log`
