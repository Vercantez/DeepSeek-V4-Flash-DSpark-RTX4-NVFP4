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

For multi-region workers, set `AWS_ASG_TARGETS` on the router. It accepts a
comma-separated list of `region:auto-scaling-group` values, for example:

```text
AWS_ASG_TARGETS=us-east-2:deepseek-rtx4-spot-asg,us-west-2:deepseek-rtx4-spot-asg-oregon
```

The regional VPCs must have private routing between the router and workers.
Rendezvous hashing is calculated across the combined healthy backend list, so
a stable sticky key remains on the same regional worker until that worker is
unhealthy or replaced.

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
- `GET /router/capabilities`

### vLLM request priority

AI Gateway must send vLLM priority as the `X-Chiridion-VLLM-Priority` request
header, not as a JSON body field. The sticky router consumes the header,
clamps it to `0..1000`, and adds vLLM's OpenAI-compatible `priority` field only
for the selected self-hosted worker. This keeps Azure and OpenRouter fallbacks
free of a vLLM-only request parameter. Lower values run first; use `0` for paid
traffic and `100` for free traffic.

## Model Contract

The router does not rewrite a request based on `/tokenize`: vLLM's tokenizer
endpoint and its final chat-generation validation can account for templates
differently. Instead, the deployed model contract is explicit:

- hard context limit: `262144` tokens
- application working context: `220000` tokens
- maximum output: `262144` tokens for an empty prompt

The application compacts before its working-context limit. By default, the
router preserves the caller's `max_tokens`; vLLM enforces the hard context
limit. `MAX_REQUEST_OUTPUT_TOKENS` is an optional operational guardrail, not a
default policy. This keeps request routing deterministic and makes vLLM the
authority for hard context validation.

## Fast Startup Notes

The working model cache is about 156 GB. Keep it on persistent EBS or inside the
AMI. Do not rely on `/opt/dlami/nvme`; it is instance-store NVMe and disappears
after Spot termination.

For fastest restarts:

1. Bake the Docker image, repo, and systemd service into a runtime AMI.
2. Keep the Hugging Face model cache on a separate snapshot-backed EBS volume
   mounted at `/opt/deepseek-cache`.
3. Set `VolumeInitializationRate: 300` on the cache-volume mapping. This gives
   snapshot hydration a predictable path without the continuous cost of Fast
   Snapshot Restore or a blocking manual cache sweep.
4. Use an ASG launch template with Spot market options and multiple subnets.
5. Keep the router on a small on-demand instance so GPU evictions do not remove
   the public API entrypoint.

### S3 To NVMe Model Staging

For production Spot recovery, prefer a versioned, regional S3 artifact over a
snapshot-backed model EBS volume. The artifact contains the dereferenced model
snapshot, vLLM compile cache, FlashInfer cache, and a SHA-256 manifest. Worker
user data downloads it to `/opt/dlami/nvme/deepseek-model`, validates the
manifest, then points `HF_CACHE` at that NVMe path before starting vLLM.

`worker-user-data-s3-nvme.sh` requires `MODEL_ARTIFACT_URI` to be set to an
immutable release prefix, such as:

```text
s3://deepseek-rtx4-artifacts-<account>-us-east-2/deepseek-v4-flash-dspark/<release>
```

`worker-user-data-mount-cache.sh` is the worker launch user-data entrypoint for
the split-cache setup. It waits for a volume labeled `deepseek-cache`, mounts it,
then starts `deepseek-rtx4.service`.
### Oregon multi-region worker pool

The Oregon launch helper requires the worker SSM instance profile so a new Spot
replacement remains privately manageable. It also mounts the copied warm cache
and enables the vLLM service to recover after a reboot.

```bash
AMI_ID=ami-... \
CACHE_SNAPSHOT_ID=snap-... \
SECURITY_GROUP_ID=sg-... \
SUBNET_IDS=subnet-...,subnet-... \
INSTANCE_PROFILE_ARN=arn:aws:iam::<account>:instance-profile/deepseek-rtx4-worker-management-profile \
./create-oregon-spot-asg.sh
```
