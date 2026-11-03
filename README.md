# Arc Pro B60 for multi-user LLM serving

Can Intel Arc Pro B60 cards (Battlemage G21, 24 GB, 456 GB/s) serve many concurrent users, not just one? This repo has what we found, a benchmark kit anyone with two B60s (or one B60 Dual) can run, and the results people have sent back. October-November 2026.

## Result so far

Qwen3.6-35B-A3B (Intel int4 AutoRound), upstream vLLM 0.32.0 XPU, TP2 on one MAXSUN B60 Dual, 1024 tokens in / 1024 out, output tok/s per chip:

| concurrency | 1 | 8 | 32 | 64 |
|---|---|---|---|---|
| XPU graph | 36.5 | 179.6 | 384.1 | 500.9 |
| eager | 8.9 | 67.6 | 234.9 | 379.1 |

0 failed requests, 117-121 W per chip at 64 concurrent, about 4.2 tok/J. Run twice by AlexanderScha (privileged on Oct 31, default unprivileged mode on Nov 2, within 1%): https://github.com/AlexanderScha/battlemage-vllm/discussions/1. Raw summaries in `results/`.

On a dense model the picture is weaker: public B70 data for Qwen3.8-27B INT4 shows 64 tok/s for one user but only 133 tok/s total at 16 users on one card, and throughput collapses at 64K context (details in `research/b60-multi-user.md`).

## Contents

- `research/b60-multi-user.md`: every public B60 multi-user number we found (graded by source quality), software status of vLLM XPU / llm-scaler / kernels, an estimate for TP2 at 32-64 users, B70 dense-model data, open questions.
- `research/16-gpu-host.md`: whether 8 B60 Dual cards (16 GPUs, 384 GB) fit and work in one host: cards, boards, servers, switches, software at 16 GPUs, power.
- `kit/`: the benchmark kit. Same files as https://gist.github.com/superresistant/f3e8338ceeb6b3d15ac305a9a219e7ba.
- `results/`: `summary.csv` from each run people shared.

## Run the kit

    git clone https://github.com/superresistant/arc-pro-b60-serving.git && cd arc-pro-b60-serving/kit
    sudo bash run.sh

About 2-3 h unattended, Docker only, leaves `b60-results-*.tar.gz` with logs, inventory and xpu-smi power. Options (GPU selection, TP/PP/EP for 4-8 GPUs, retries) are in `kit/README.md`.

Most wanted: 8-GPU rigs (`sudo TP=4 PP=2 bash run.sh`, `sudo TP=8 EP=1 bash run.sh`), hosts with a PCIe switch, B70 at TP1 and TP2. Open an issue and attach the tarball.
