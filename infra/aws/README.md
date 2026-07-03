# AWS RTX4 Spot Service

This directory contains the prototype deployment shape for serving
`DeepSeek-V4-Flash-DSpark` on `g7e.24xlarge` RTX PRO 6000 Blackwell hosts.

## Shape

- GPU workers run in an Auto Scaling Group with Spot capacity.
- Each GPU worker starts `deepseek-rtx4.service`, which runs the tested
  `vllm-dspark-runtime:rtx4-nvfp4-port-v3` container with:
  - `KV_CACHE_DTYPE=nvfp4_ds_mla`
  - DSpark speculative decoding enabled
  - `MAX_NUM_SEQS=64`
  - `MAX_NUM_BATCHED_TOKENS=8192`
- A small on-demand router node runs `deepseek-sticky-router.service`.
- The router discovers healthy ASG workers through AWS APIs and forwards
  OpenAI-compatible traffic to `http://<worker-private-ip>:8000`.

## Sticky Routing

The router picks a backend with rendezvous hashing. Send one of these headers
to keep a user/session/conversation on the same GPU host:

- `X-Sticky-Key`
- `X-Session-ID`
- `X-Conversation-ID`
- `X-User-ID`

If no sticky header exists, the router falls back to the OpenAI `user` JSON
field, then the first message prefix, then the `Authorization` header. Explicit
sticky headers are preferred because they avoid accidentally grouping many users
behind one API key.

Health endpoints:

- `GET /healthz`
- `GET /router/backends`

## Fast Startup Notes

The working model cache is about 156 GB. Keep it on persistent EBS or inside the
AMI. Do not rely on `/opt/dlami/nvme`; it is instance-store NVMe and disappears
after Spot termination.

For fastest restarts:

1. Bake the Docker image, repo, systemd service, and Hugging Face model cache
   into an AMI.
2. Use an ASG launch template with Spot market options and multiple subnets.
3. Keep the router on a small on-demand instance so GPU evictions do not remove
   the public API entrypoint.
