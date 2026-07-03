# RTX PRO 6000 Blackwell x4 Run Summary

AWS instance:
- `g7e.24xlarge` in `us-east-2a`
- 4x NVIDIA RTX PRO 6000 Blackwell Server Edition, ~96 GiB each
- Driver `580.159.04`

Working server profile:
- Model: `deepseek-ai/DeepSeek-V4-Flash-DSpark`
- vLLM image: `voipmonitor/vllm:eldritch-enlightenment-v2226f26-b12x15cd38c-cu132-20260629`
- Tensor parallelism: `4`
- Backend: `lucifer-cutlass`
- Attention backend: `FLASHINFER_MLA_SPARSE_DSV4`
- MoE backend: `flashinfer_cutlass`
- Speculative decoding: DSpark, `num_speculative_tokens=5`, `draft_sample_method=probabilistic`
- KV cache dtype: `fp8`
- `max_model_len=262144`
- `max_num_seqs=64`
- `max_num_batched_tokens=8192`

Startup milestones:
- Full model weights loaded successfully.
- DSpark draft weights loaded successfully.
- FlashInfer SM120 sparse MLA DSv4 decode autotune ran.
- DSpark block-forward CUDA graphs captured.
- OpenAI-compatible API reached `Application startup complete`.
- Smoke test passed: `4/4` concurrent requests succeeded.

Decode-heavy benchmark:
- Benchmark script: `benchmarks/bench_concurrent.py`
- Prompt: CRUD-heavy Python module completion prompt
- `max_tokens=256`, `ignore_eos=true`, streaming responses
- Best aggregate throughput:
  - `x1`: `277.6 tok/s`
  - `x4`: `733.2 tok/s`
  - `x8`: `1274.3 tok/s`
  - `x16`: `1668.2 tok/s`
  - `x32`: `2810.2 tok/s`
  - `x48`: `3216.2 tok/s`
  - `x64`: `3364.9 tok/s`
- DSpark acceptance during high-concurrency tests: about `0.67-0.69`

NVFP4 compatibility result:
- `KV_CACHE_DTYPE=nvfp4_ds_mla` is rejected by this image as an invalid dtype.
- `KV_CACHE_DTYPE=nvfp4` is accepted by the CLI parser, but rejected by vLLM config validation:
  `nvfp4 KV cache is not supported with MLA (Multi-head Latent Attention) backends. Please use a different --kv-cache-dtype (e.g., 'fp8' or 'auto') for MLA models such as DeepSeek.`
- Conclusion: on this vLLM/DeepSeek V4 Flash DSpark stack, RTX PRO 6000 Blackwell can run DSpark with FP8 KV cache, but cannot run NVFP4 KV cache for DeepSeek MLA.

