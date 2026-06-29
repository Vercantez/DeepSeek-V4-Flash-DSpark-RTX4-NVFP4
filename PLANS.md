# Runtime Merge Plan

## Scope
- Merge the Keys/Tony DSpark concurrency runtime improvements into this repo.
- Preserve the hardened local helper scripts for build/prepare/start/stop stability.
- Update README to describe the stronger concurrency runtime basis and the current 500k/4-session profile.

## Assumptions
- The Tony repo contains the applied Keys concurrency patch in the overlay files.
- The current local operational target remains `MAX_MODEL_LEN=500000` and `MAX_NUM_SEQS=4`.
- The 500k/4 profile is a target profile; published measured concurrency evidence remains the 200k/16 Keys checkpoint and the 1M/1 checkpoint.

## Files
- Bring in `CREDITS.md`.
- Bring in `patches/keys-concurrency.patch`.
- Bring in `benchmarks/20260629-dspark-keys-concurrency-checkpoint.md`.
- Bring in `benchmarks/keys-concurrency/`.
- Replace the three patched overlay files:
  - `recipe/overlay/vllm/models/deepseek_v4/nvidia/dspark.py`
  - `recipe/overlay/vllm/v1/spec_decode/dspark_proposer.py`
  - `recipe/overlay/vllm/v1/worker/gpu_model_runner.py`

## Non-Goals
- Do not change `docker-compose.dspark.yml`.
- Do not change local `.env.dspark`.
- Do not weaken the hardened helper scripts.
- Do not run build/start/stop/download as validation.

## Validation
- `bash -n` on helper scripts.
- `scripts/verify-overlay-sources.sh`.
- `docker compose config` render check.
- Static check that Keys patch markers are present in overlay files.
