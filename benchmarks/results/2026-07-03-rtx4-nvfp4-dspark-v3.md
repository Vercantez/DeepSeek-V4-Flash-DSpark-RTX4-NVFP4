# RTX PRO 6000 x4 NVFP4 DSpark Port Result

Instance:
- AWS `g7e.24xlarge`, 4x RTX PRO 6000 Blackwell, `us-east-2a`

Runtime:
- Base image: `voipmonitor/vllm:eldritch-enlightenment-v2226f26-b12x15cd38c-cu132-20260629`
- Port image: `vllm-dspark-runtime:rtx4-nvfp4-port-v3`
- Model: `deepseek-ai/DeepSeek-V4-Flash-DSpark`
- Served name: `deepseek-v4-flash-dspark`
- Tensor parallelism: `4`
- Backend: `lucifer-cutlass`
- Attention backend: `FLASHINFER_MLA_SPARSE_DSV4`
- KV cache dtype: `nvfp4_ds_mla`
- Speculative decoding: DSpark, `num_speculative_tokens=5`, probabilistic draft sampling
- `max_model_len=262144`
- `max_num_seqs=64`
- `max_num_batched_tokens=8192`

Patch result:
- The exact DGX Spark image from the reference repo is ARM64 and does not run directly on this x86 RTX host.
- The x86 port needed additional DeepSeek V4 cache-layout patches beyond dtype plumbing:
  - main MLA cache shape maps `nvfp4_ds_mla` to the packed 584-byte DeepSeek V4 layout
  - SWA cache shape maps `nvfp4_ds_mla` to the packed 584-byte layout
  - cache alignment for the packed layout is 584 bytes
- Earlier failures:
  - `Expected packed SM120 DSV4 swa_kv_cache head dim 584, got 512`
  - `Expected packed SM120 DSV4 compressed_kv_cache head dim 584, got 512`
- v3 booted successfully after patching both cache paths.

Validation:
- API readiness passed via `GET /v1/models`.
- Smoke test passed: `2/2` chat requests succeeded.
- Server logs confirmed:
  - `Using probe DeepSeek V4 nvfp4_ds_mla KV cache format`
  - `DSpark draft weights loaded`
  - DeepSeek V4 mHC warmup completed
  - FlashInfer SM120 sparse MLA DSv4 autotune cache loaded
  - CUDA graph capture completed
  - DSpark eager warmup completed

Benchmark:
- Script: `benchmarks/bench_concurrent.py`
- `max_tokens=256`, streaming, `ignore_eos=true`
- Best aggregate decode throughput:
  - `x1`: `303.5 tok/s`
  - `x4`: `738.1 tok/s`
  - `x8`: `1263.3 tok/s`
  - `x16`: `1670.2 tok/s`
  - `x32`: `2884.0 tok/s`
  - `x48`: `3262.7 tok/s`
  - `x64`: `3288.1 tok/s`
- DSpark acceptance:
  - benchmark acceptance range: about `0.65-0.71`
  - server metric at x64: average draft acceptance rate `67.1%`, mean acceptance length `4.36`

Notes:
- This proves the full DeepSeek V4 Flash DSpark model can run on the x4 RTX PRO 6000 Blackwell box with the experimental `nvfp4_ds_mla` path.
- Throughput is similar to the prior FP8 KV run on the same instance, not materially higher in this first port.
- Remaining work before treating this as production-grade:
  - longer correctness soak
  - compare output quality against FP8 KV and a trusted hosted baseline
  - run longer latency distribution tests with realistic prompts
  - package the v3 patches as reviewable source patches rather than Dockerfile text replacements
