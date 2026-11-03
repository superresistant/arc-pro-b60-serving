# Arc Pro B60 multi-user serving: sourced numbers and status

First written 2026-10-28, updated 2026-11-03.

Grades: A = primary source with flags, versions and method; B = primary but partial method; C = secondary or AI-aggregated. Comm = community, Vend = vendor or integrator. All tok/s figures are output tokens. "/GPU" means one chip (a B60 Dual board has two).

## (a) Measured numbers at concurrency >= 8 (new data first, then context already known)

Qwen3.6-35B-A3B (the target model)

| setup | stack | conc | total | /GPU | source, date, grade |
|---|---|---|---|---|---|
| 2x B60 TP2, online sym_int4, ~512 out, short prompts, Xeon 6130 | llm-scaler 0.26.0-b2 (= PV 1.5), eager | 32 | 657.5 | 329 | jsetsuda, https://github.com/intel/llm-scaler/issues/596 (comment 2026-09-14), 1.5 h soak, 6,624 requests, Comm A |
| same, XPU graph | same + #700 patch | 32 | 374.2 | 187 | same; graph -43% at TP2 on B60, +89% on B70 |
| 1x B60 TP1, same | same, eager / graph | 32 | 336.6 / 322.2 | 337 | same; KV only 81K tokens at 0.90 util |
| 4x B60 TP4, FP8 | llm-scaler 0.21.0-b3, eager / graph (capture sizes 1-8) | 8 | 290.5 / 494.3 | 73 / 124 | AlexanderScha (4x MAXSUN B60 Dual, W790), https://github.com/AlexanderScha/battlemage-vllm/blob/main/measurements/xpu-graphs-b60.md, 2026-08-11, Comm A |
| 1x B60 TP1, 4-bit, i9-9900K, PCIe 3 | llm-scaler, eager | 8 / 16 | 300 / ~410 | same | CARouter, https://carouter.ai/blog/qwen3-6-35b-a3b-on-two-intel-arc-pro-b60, 2026-10-09, Vend B |
| 2x B60, one engine per card | same | 32 (16/card) | 818 | 409 | same |
| 1x B60, XPU graph | llm-scaler + logging patch | 8 | 349 (vs 282 eager) | 349 | CARouter, https://carouter.ai/blog/qwen3-6-35b-a3b-79-percent-faster-on-intel-arc-pro-b60, 2026-10-12, Vend B. One host thread at 100% from c1 to c16: host-bound |
| 1x B70, 35B-class, 32 users | vLLM, Linux | 32 | "500+" | 500+ | SMZDM AI summary of Bilibili, https://post.smzdm.com/p/arzrrmgq/, 2026-10-18, C |

Other models on B60

| setup | stack | conc | total | /GPU | source, date, grade |
|---|---|---|---|---|---|
| 4x B60 TP4, Qwen3-VL-30B-A3B | vLLM 0.12 / llm-scaler 1.2 | 64 | ~1,000 peak | ~250 | EmbeddedLLM, https://embeddedllm.com/blog/benchmarking-llm-inference-intel-arc-pro-b60, 2026-02-14, Vend B |
| 4x B60, gpt-oss-20b MXFP4 TP1 | intel/vllm 0.21.0-xpu | 8 | 241 | 241 | Ninabot, https://ninabot.ch/en/anchor/benchmarks/, 2026-09-10, Vend B |
| 2x B60 TP2, Qwen3.8-27B GPTQ-Int4, MTP6, k8v4 KV | vLLM XPU 0.30 + custom cache | 8 | 301-344 | 150-172 | Daniel00Higgins, https://x.com/Daniel00Higgins/status/2105151154262769891, 2026-09, Comm B |
| 8x B60 (4 Duals), gpt-oss-120b | MLPerf v6.0 | offline/server | 1,602 / 884 | 200 / 110 | already known, Vend A |
| 4x B60, gpt-oss-120b, 1K/1K | Intel vLLM blog, Nov 2025 | 100 | 1,495 | 374 | already known, Vend B |

B65/B70 (known): B65 TP1 upstream vLLM 0.32 c192 1,360/GPU; 1x B70 INT4 c64 1,140. No B60 run on upstream vLLM 0.31/0.32 at c >= 8 found. Power: nothing new beyond 95-150 W/GPU.

## (b) Software status

- vllm-xpu-kernels #457 (graph-capture-safe Xe2 grouped GEMM): still open. Its author, 2026-10-24: #586 already fixes the capture crash and is faster on long tiles; his V2 is 1-5% faster on Qwen3.6-35B-A3B, 4-10% slower elsewhere. https://github.com/vllm-project/vllm-xpu-kernels/pull/457
- #586 (zero the grouped-GEMM atomic_buffer, race fix): merged 2026-09-10, verified in v0.1.15. vLLM v0.31.0 and v0.32.0 (2026-10-18) pin vllm_xpu_kernels 0.1.15.4 with torch 2.14, so stock upstream images already have the fix. No published measurement of its batched-decode gain. https://github.com/vllm-project/vllm-xpu-kernels/pull/586
- MoE fixed per-step cost (#509, open): 5-6.6 ms/step on B70. Intel says XPU graph replay does not remove most host overhead yet and points to torch 2.14 (now shipping). Int4 GEMV for <= 8 rows: #644, open; it does not help at c32-64. https://github.com/vllm-project/vllm-xpu-kernels/issues/509
- Graph capture with batch > 1 on B60: works on llm-scaler with capture sizes <= 8. Default sizes fail at 16 with UR_RESULT_ERROR_OUT_OF_RESOURCES (torch 2.13 fork). FMHA is not capturable, so mode is PIECEWISE. FP8 MoE ref path fails capture on 2x B70 TP2 (#567, open). Graph mode raises repetition 41x on Qwen3.6-35B-A3B int4 (#596) and produces garbage on gpt-oss-120b TP4 (#698). On stock llm-scaler 1.5, sym_int4 + graph does not start without a logging patch (#699).
- TP2 stability: DEVICE_LOST or hang on 0.26.0-b2 TP2 on 2x B70 (#723, open; b1 works); DP2xTP2 hang on 4x B60 (#731); GPTQ checkpoints DEVICE_LOST at profile_run on B60 upstream (vllm #52203, open since 2026-08-13); moe_gather faults on TOPK=10 (#559). User fixes: CCL_SYCL_* thresholds (llm-scaler #595), CCL_MNIC_NAME=lo, no risers, check root-port link (a Gen2 x8 slot cost 74% MoE throughput).
- llm-scaler PV 1.5 (2026-10-16) = 0.26.0-b2 (vLLM 0.26, kernels 0.1.11.2, torch 2.12): validates Qwen3.6-35B-A3B, online FP8/sym_int4, MTP, prefix caching + MTP fix, FP8 KV; XPU graph experimental; no performance numbers in the notes (reference_perf_b60.csv only in the offline installer). 0.31.0-b1-experimental: single-stream 40% slower as shipped (#772).
- MTP under concurrency: mixed-spec-batch fix landed (kernels #510); CARouter: MTP hurts from c4. GDN state fixes still landing (#657 fixed 2026-10-26, #659 open).

## (c) Estimate: Qwen3.6-35B-A3B 4-bit, TP2, c32-64, one B60 Dual

Floor, measured: 329 tok/s/GPU at c32 (llm-scaler 1.5, eager, sym_int4, short prompts, 2017 Xeon host). At c32 TP1 gives 337, so TP2 costs nothing per GPU in this host-bound regime.
Supported range: 330-450 tok/s/GPU. Central estimate ~400.
- Fast host CPU: CARouter's 5 GHz desktop CPU reaches 409/GPU at c16 TP1, eager. A modern Xeon/EPYC host should land near that; c64 adds batch, but the host fixes the step cost.
- XPU graph: +24% at c8 on one B60 (CARouter) and +70% at c8 TP4 (AlexanderScha), but -43% at c32 TP2 (jsetsuda). There is no clean B60 graph result at c32-64.
- Upstream vLLM 0.32 (#586, torch 2.14) is the only route seen above 600/GPU: B65 1,360 at c192 TP1. Scaled to B60 bandwidth (x0.75), that is about 1,000 at very high concurrency and TP1. At c32-64 with TP2 allreduce over x8/x8 PCIe without a switch, that would give ~500-700, if the upstream path runs on B60 at all. GPTQ DEVICE_LOST (#52203) has not been retested.
- Roofline: ~64% of experts touched per step at c32 → ~6.4 GB read per GPU per TP2 step → ~1,100 tok/s/GPU at 456 GB/s; measured stacks reach 28-35% of that (memory-bandwidth utilisation).
Going beyond about 400 tok/s/GPU at c32-64 needs graph or host-overhead gains shown on B70/B65, not yet on B60 when this estimate was written (see the measurement below).

## Measured with our kit

2026-10-31, AlexanderScha (https://github.com/AlexanderScha/battlemage-vllm/discussions/1#discussioncomment-19261954 thread), kit revision 7e21f283, one MAXSUN B60 Dual, Xeon w7-3465X on W790, x8 Gen5 root ports, upstream vllm-openai-xpu v0.32.0, TP2, PRIVILEGED=1: graph c1/c8/c32/c64 = 36.5/179.6/384.1/500.9 tok/s/GPU, eager 8.9/67.6/234.9/379.1; 0 failed requests; TTFT median 653 ms, p99 11.6 s at c64 (burst arrival); 117-119 W per chip at c64 (idle chips about 35 W), 4.2 tok/J. Graph output correct 16/16 on his check prompts. The unprivileged default failed on hosts with more than 2 GPUs (oneCCL drmfd opened every by-path render link); fixed in kit revision 8e92a1b4.

2026-11-02, same box and chips, kit 8e92a1b4, default unprivileged mode (https://github.com/AlexanderScha/battlemage-vllm/discussions/1#discussioncomment-19348072): graph 36.5/179.5/385.0/500.6 tok/s/GPU, eager 8.8/66.9/234.9/377.8, within 1% of the privileged run, 119-121 W per chip at c64 (xpu-smi). Raw summaries: `results/`.

## B70 on a dense model

Nov 2 2026, Donato Capitella (video https://www.youtube.com/watch?v=Rxh8ouzTEbM, data https://local-llm-benchmarks.dev/data/results.json): dense Qwen3.8-27B RedHat INT4 on upstream vLLM XPU 0.31, HTTP coding-agent depth curves. c1 MTP3 64 tok/s (1x B70) / 105 (TP2). Batch without MTP scales poorly: 1x c4/8/16 = 89/119/133 aggregate, TP2 113/162/193, and at 64K depth aggregate falls to 4 (1x c8) / 65 (TP2 c8) / 12 (TP2 c16), KV-bound. Same-model RTX 3090 reference: about 1,035 aggregate at c64 on one 3090 (https://github.com/syv-ai/qwen38-27b-rtx3090, other engine and quant). B60 = 456 vs 608 GB/s and 24 vs 32 GB, so expect ≤0.75x these on dense 27B. Implication: on dense models the XPU stack is single-user grade today; the MoE result above (35B-A3B, 501 tok/s/chip at c64) is the strongest B60 result. Software traps: llm-scaler MTP + prefix caching corrupts long replies; EXL3-XPU (trellis-serve) no working prefix caching; llama.cpp SYCL Q4_K_XL needs the optimized weight path disabled for coherent output.

## (d) Ways to measure without owning cards

1. Run `kit/` on an existing B60 or B70 rig and share the tarball (open an issue). Most wanted: 8 GPUs (TP4 x PP2, TP8 with EP), hosts with a PCIe switch (P2P), B70 TP1/TP2.
2. GigaGPU dedicated B60, £129/month, UK, Ryzen host, bare metal: https://gigagpu.com/intel-arc-pro-b60-hosting/. Only single B60 is listed: a TP1 c32-64 number and a host-overhead check, not TP2.
3. AM ThermaLink, 1x B70 at $0.23/GPU-h, browser terminal (via gpus.io; root/Docker unknown): https://amthermalink.com. B70 TP1 proxy, scale by x0.75 bandwidth for B60.
4. Zed Up (Germany) B60 card rental, up to 6 months (VideoCardz Nov 2025; status unverified). No public Arc Pro B listing found on Intel cloud, Vast or RunPod-type markets.

## (e) Still unknown

- Any B60 result on upstream vLLM 0.31/0.32 (kernels 0.1.15.4, torch 2.14) at c >= 16 on Qwen3.6-35B-A3B. This is the decisive cell.
- Whether graph capture at sizes 16-64 works on B60 with torch 2.14 upstream (it fails at 16 on the fork's torch 2.13), and why graph mode loses 43% at TP2 c32 on B60 while it gains 89% on B70.
- TP2 on a B60 Dual (x8/x8, no switch, P2P through the root complex) vs two TP1 replicas. Both 24 GB chips fit the 35B 4-bit, but TP1 KV is ~81K tokens, which is enough for c32 at 2K but not for long prompts.
- GPTQ/AutoRound int4 on B60 upstream (#52203 DEVICE_LOST). Our kit uses Intel/Qwen3.6-35B-A3B-int4-mixed-AutoRound, so an FP8 or sym_int4 fallback arm is worth having.
- Host CPU sensitivity (every B60 result is host-bound), power at c32-64, graph-mode correctness at scale.

Kit notes (`kit/`): stock v0.32.0 already contains #586, so the stock arm is the real baseline. The default capture list [1..64] may abort at size 16; a CAPTURE_SIZES=[1,2,4,8] fallback avoids a lost run.
