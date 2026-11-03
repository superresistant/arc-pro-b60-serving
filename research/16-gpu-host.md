# 8x Arc Pro B60 Dual (16 GPUs, 384 GB) in one host: sourced answer, 2026-10-29

Tags: Vend = vendor/marketing, Meas = measured by a third party, Inf = my inference. Known = b60-multi-user.md.

Short answer: yes, a single host can hold and enumerate 16 B60 GPUs; Sparkle sells servers built for exactly this. Serving one model across all 16 is unproven: no public TP16 or TP8xPP2 run on Battlemage exists. TP8 works on 8x B70. The realistic single-box layout is TP8xDP2 or TP4xDP4, which serves the same models as two 4-Dual boxes.

## 1. The card

- MAXSUN B60 Dual 48G Turbo: 300x110x40 mm, 2-slot, blower, 1x 12V-2x6, 400 W TBP, 2x PCIe 5.0 x8. https://www.maxsun.com/products/intel-arc-pro-b60-dual-48g-turbo (read 2026-10-29, Vend). A Fanless vapor-chamber version for server airflow has the same 400 W and 12V-2x6, 302x110x40 mm. https://www.maxsun.com/products/ms-intel-arc-pro-b60-dual-48g-fanless (Vend)
- No onboard bridge: the slot must be bifurcated x8/x8. LTT found no such option on ASUS Z890 Hero or Pro WS TRX50-SAGE. https://www.lttlabs.com/articles/2026/05/15/maxsun-intel-arc-pro-b60-dual-48g-turbo-review (2026-05-15, Meas)
- Firmware: Above 4G decoding and Re-Size BAR on (https://www.intel.com/content/www/us/en/support/articles/000099073/graphics.html, Vend). Each GPU maps a 32 GB BAR (https://github.com/skipzx-lab/precision-5820-arc-b60-large-bar, Meas), so 16 GPUs need about 512 GB of high MMIO (Inf).
- Power under LLM load: known, about 95 W per GPU (xpu-smi, 4 Duals) and 95-150 W in b60-multi-user.md. Idle: 7-9 W per GPU in nvtop. https://forum.level1techs.com/t/llm-adventures-with-intel-arc-pro-b60s-p2p-vllm/252516 (2026-07-11, Meas)
- Other Dual: SPARKLE SBP60DP-48G (passive, 12V-2x6); no switch is mentioned. https://videocardz.com/newz/sparkle-arc-pro-b60-dual-48gb-revealed-unusual-hdmi-placement-12v-2x6-connector-nad-passive-cooler (Vend). No ASRock or Gunnir Dual and no Dual with an onboard switch found.

## 2. Hosts

a. Single-root workstation boards
- ASUS WRX90E-SAGE SE: 6x Gen5 x16 + 1 slot at x8; 6 slots offer x8x8 after a BIOS update, so the cap is 6 Duals (12 GPUs), on risers. https://forum.level1techs.com/t/asus-wrx90e-sage-x8-x8-bifurcation/207260?page=3 (Comm). No 7-slot board fits more than 3-4 double-width cards without cables (Inf).
- Cable route: ASRock Rack GENOA2D24G-2L+ (2x SP5) has 20 MCIO PCIe 5.0 x8 connectors. https://www.connection.com/product/asrock-asrock-rack-genoa2d24g-2l/genoa2d24g-2l/41935698 (Vend). 16 of them feed 8 C-Payne "MCIO gen5 Device Adapter" boards (two MCIO 8i in, one x16 slot out, €50). https://c-payne.com/products/mcio-pcie-gen5-device-adapter-x8-x16 (Vend). Each GPU then gets its own CPU x8 link with no BIOS bifurcation. Inf, not tested with a B60 Dual.

b. 4U GPU servers
- Sparkle C741-4U-8P: dual Xeon 4th/5th gen, 8x PCIe 5.0 x16 double-wide slots, all CPU-direct ("Switchless"), 4x 2,700 W Titanium (3+1). Listed as "up to 384GB VRAM, 8x Arc Pro B60 Dual". This is the exact target. https://www.harmonytechnical.com/industrial-computer-solutions/ai-edge-computing/ (reseller page, Vend)
- Sparkle C741-6U-16P: 16 Duals (32 GPUs) behind Microchip switches, 5x 2,700 W. A switch can therefore present x8x8 per slot. https://tech.yahoo.com/computing/articles/sparkle-server-16-arc-pro-130200154.html (TechRadar, 2025-10-12, Vend)
- Supermicro AS-4125GS-TNRT: 2x EPYC 9004/9005, up to 8 direct-attached double-width GPUs, 9x PCIe 5.0 x16, 4x 2,000 W. https://www.asacomputers.com/supermicro-as-4125gs-tnrt-4u-server.html?mode=spec (Vend). Its H13DSG-O-CPU manual has a per-slot bifurcation setting (p.58). https://www.manualslib.com/manual/3158556/Supermicro-H13dsg-O-Cpu.html (snippet only). Unverified: an x8x8 option on the GPU slots, and 12V-2x6 cabling.
- ASUS ESC8000A-E12: 8 dual-slot Gen5 x16 GPU slots, 4x 3,000 W; bifurcation unknown. https://servers.asus.com/products/Servers/GPU-Servers/ESC8000A-E12 (Vend)

c. Switch boards
- C-Payne PM50100 (Switchtec Gen5, €2,700, sold out): x16 uplink, 12 MCIO 8i, bifurcation and partitions configurable. With 10 x8 downstream ports, two boards would host 8 Duals (Inf). https://c-payne.com/products/pcie-gen5-mcio-switch-100-lane-microchip-switchtec-pm50100 (Vend)
- hoborific's PEX88096 board (Gen4): DIP switches set each slot to x16, x8/x8 or 4x x4, up to 10 x8 devices. It runs 8 B60s with P2P after a list of `pci=disable_acs_redir=` entries. P2P gives +65-70% on prefill/TTFT (Gemma-4-31B TP4). Level1Techs link above (Meas).

d. Battlematrix: "up to eight B60 GPUs" means 8 chips on 4 Dual cards (192 GB). https://www.storagereview.com/review/intel-arc-pro-b60-battlematrix-preview-192gb-of-vram-for-on-premise-ai (Vend). No public build of 12-16 B60s found; MLPerf v6.1 Intel submitted 4x B70 only. https://wccftech.com/mlperf-v-6-1-benchmarks-nvidia-amd-intel-blackwell-vera-rubin-mi355x-arc-b70/

## 3. Software at 16 GPUs

- No 8-device cap found in llm-scaler, vLLM or vllm-xpu-kernels issues or docs.
- TP8 works: 8x B70 on a Xeon 6530P, llm-scaler 0.26.0-b2, Qwen3-Coder-Next, FP8 OK. sym_int4 is unsupported for that model (garbage output, crash at batch >1). https://github.com/intel/llm-scaler/issues/722 , /735 (2026-09, Meas). A TP8-only kernel bug was fixed in #436 (2026-05).
- TP16: no public run. vLLM needs the head count divisible by TP: Qwen3.8-Flash-Next has 24 heads, so TP16 is impossible for it (Inf, from config.json).
- Collective cost: each oneCCL all-reduce makes 85-91 Level Zero calls and blocks the host for 42-56 µs; a dense 27B issues 129 per token. On B70, TP2 eager ran at 61% of TP1, and graph capture plus a custom 2-rank all-reduce reached 159%. https://github.com/vllm-project/vllm/issues/54766 (2026-09-01, Meas). TP16 adds per-step cost (Inf).
- PP: host RAM leak without P2P (#590), PP2/PP3 hangs (#489, #753), all open. DP2xTP2 hang on 4x B60 (#731, known).
- A riser's signal integrity reset the B70 copy engine; the rig ran stably once the riser was removed. https://www.pugetsystems.com/labs/articles/intel-arc-pro-b70-multi-gpu-ai-inference-performance/ (2026-09, Meas).
- Multi-node: the llm-scaler README documents Ray PP/TP across nodes; 7B example, no performance data. https://github.com/intel/llm-scaler/blob/main/vllm/README.md (2026-10-26, Vend)

## 4. What 384 GB holds (HF API, 2026-10-29). Usable is about 345 GB at 0.9 utilization.

| model | params | native | fits | vLLM XPU |
|---|---|---|---|---|
| Kimi-K3 | 2.78T | 1,561 GB | no | n/a |
| GLM-5.3 | 753B | FP8 756 GB; GGUF Q4_K_XL 467, Q3_K_XL 343 | only ≤Q3 GGUF (llama.cpp, not vLLM) | GLM-5 plan open (vllm-xpu-kernels #224) |
| DeepSeek-V4.1-Flash(-1017) | 763B | 510 GB (FP8, FP4 experts); GGUF Q2_K_XL 335 | only ~2-bit GGUF | no: init test skipped on XPU (vllm #61364) |
| GLM-5.3-Flash | 321B | FP8 328 GB; Q4_K_XL 200 | 4-bit yes, ~145 GB KV | no XPU work found |
| MiniMax-M3.1-Flash | 220B | MXFP8 252 GB; Q4_K_XL 249 | FP8 yes, ~90 GB KV | XPU PR #45881 open since 2026-06 |
| Qwen3.8-Flash-Next | 180B | BF16 360 GB | FP8 ~180 GB yes (Inf) | llm-scaler 0.31.0-b1-experimental only; TP4 B70 concurrency collapse (#773); upstream PR #61607 open |

Sources: https://huggingface.co/api/models/<repo> and the unsloth/*-GGUF trees. None of the 2026 MoEs that fit has a merged vLLM XPU path. What runs today at TP4/TP8: the Qwen3.6/3.8 class, Qwen3-Coder-Next, gpt-oss-120b.

## 5. Power and electrical

- GPUs: 16x 95-150 W = 1.5-2.4 kW (known, measured); nameplate 8x 400 W = 3.2 kW. Dual-socket host about 0.6-1.0 kW (Inf). Sustained total is about 2.2-3.4 kW, about 4.2 kW at nameplate.
- 230 V/16 A gives 3.7 kW: use 2x 16 A or 1x 32 A. Servers ship 4x 2.0-3.0 kW PSUs; an open frame needs 2x 2,000 W+ (Inf).
- Cooling: the vendor design is blower or fanless cards in a 4U front-to-back airflow chassis. Waterblocks only suit an open frame and add 16 leak points (Inf).

## 6. Bottom line

Physically feasible. Cleanest build: Sparkle C741-4U-8P (switchless, listed for exactly 8x B60 Dual, price by quote only). Second choice is the Supermicro AS-4125GS-TNRT + 2x EPYC + 384-512 GB RDIMM. The barebone was $7,494 at Newegg (2023, out of stock) and $11,518 at Broadberry for the TNRT2. Non-GPU parts come to roughly €12-20k (Inf). Cheapest is an open frame: GENOA2D24G-2L+, 16 MCIO x8 cables, 8 C-Payne adapters and 2 PSUs, about €4-7k plus CPUs and RAM (Inf), with riser/SI risk.

Main risk: software, not slots. A dual-socket box splits the GPUs across 2 NUMA nodes, which maps to TP8 per socket x DP2. That serves the same models as two 4-Dual W790/W890 boxes (AlexanderScha, known; Sparkle W790-WS-4P/W890-WS-4P, Vend). One model across 16 GPUs (TP16, TP8xPP2, or two-box PP over Ethernet) has no Battlemage evidence, and PP is the buggiest path. The single box only wins once TP16/PP2 works or a 200-345 GB model gets XPU support.

## Remaining unknowns, ranked, with the cheapest way to settle each

1. TP8 and TP8xPP2 on B60 under concurrency: ask hoborific (8x B60, switch, P2P) to run TP8 and PP2 of Qwen3.6-35B-A3B. Free.
2. Sparkle C741-4U-8P price, lead time, EU availability, MAXSUN-card fit: quote request (Sparkle or Harmony form). Free.
3. Supermicro H13DSG-O x8x8 option on the GPU slots, plus 12V-2x6 cables: ask the reseller or Supermicro support. Free.
4. B60 P2P across root ports or sockets without a switch, and the ACS recipe: xpu-smi topology from AlexanderScha or jsetsuda. Free.
5. XPU support for GLM-5.3-Flash and MiniMax-M3.1-Flash: alert on vllm #45881, #61607 and vllm-xpu-kernels #224. Free.
6. Room for 16x 32 GB BARs in the chosen BIOS: ask in the quote. Free.
7. Two-box Ray PP throughput over 25/100 GbE: nothing published; needs our own test after the first 4 Duals.
