# B60 multi-user throughput kit

Measures Qwen3.6-35B-A3B (Intel int4 AutoRound) on upstream vLLM 0.32.0 XPU, tensor parallel 2 on two B60s, at 1, 8, 32 and 64 concurrent requests (1024 in / 1024 out). Two arms by default: XPU graph (PIECEWISE, falls back to capture sizes 1-8 if the full list fails) and `--enforce-eager`. Everything runs in Docker, unattended.

Requirements: Linux with the `xe` driver on both GPUs, Docker, about 30 GB free in this folder (model 22 GB) and 20 GB free in Docker's data root (image 5 GB download, about 15 GB on disk), 32 GB RAM. No Hugging Face account needed. Nothing else should use the two GPUs during the run.

Run:

    git clone https://gist.github.com/f3e8338ceeb6b3d15ac305a9a219e7ba.git b60-kit && cd b60-kit
    sudo bash run.sh

or detached: `sudo nohup bash run.sh >/dev/null 2>&1 &` then `tail -f out/run.log`. `sudo DRY=1 bash run.sh` prints the plan without downloading anything.

Pick the two GPUs with `GPU_BDFS="0000:18:00.0 0000:19:00.0"` (default: the two lowest-BDF Battlemage devices; for a Dual card take its two adjacent devices from `lspci -nn -d 8086: | grep '\[8086:e2'`). The script stops early if it finds fewer than two Battlemage GPUs. Optional extra arm: `ARMS="stock stock-eager pr457"` builds vllm-xpu-kernels PR #457 (1-2 h compile, about 20 GB more in this folder and 20 GB more in Docker).

Takes about 2-3 h including downloads (each level runs a short warmup, then 16 prompts at c1 and 4x c prompts above). If interrupted, rerun the same command: finished steps are skipped. For a new attempt after changing settings, use a fresh folder or `sudo rm -rf out` first: finished levels in an existing `out` are kept, including rows of a failed earlier attempt. An arm that crashed or failed to start is not retried automatically: `sudo RETRY=1 bash run.sh` retries it, `sudo RETRY=1 PRIVILEGED=1 bash run.sh` if the server log shows Level Zero or oneCCL device errors inside the container (with PRIVILEGED=1 the container sees every GPU and vLLM takes the first two, whatever GPU_BDFS says). The server never listens outside the container (127.0.0.1 inside, no published port); on exit or Ctrl-C the `b60-serve` container is removed.

Result: `b60-results-<host>-<date>.tar.gz` in this folder (a few MB: hardware/software inventory, logs, bench JSON with the generated gibberish, xpu-smi power). Readable summary in `out/summary.txt`. Note: besides graphs, the eager arm also runs vLLM's own custom ops and norm/act quant fusions (graph arm: Inductor, `custom_ops: none`), so graph/eager mixes two effects. The tarball contains your hostname, kernel/driver/package versions, `lspci -vv`, `docker info`, GPU-related dmesg lines and the path of this folder; GPU serial numbers and the Docker Hub username are redacted. Check `out/inventory/` before sending if you care.

Cleanup: `sudo rm -rf cache out out-dry *.tar.gz` and `sudo docker rmi vllm/vllm-openai-xpu:v0.32.0` (plus `b60-vllm-pr457:local b60-xpu-kernels-builder:local intel/deep-learning-essentials:2026.1.2-devel-ubuntu24.04` after the pr457 arm).

More GPUs: `sudo TP=4 PP=2 bash run.sh` (pipeline) or `sudo TP=8 EP=1 bash run.sh` (8-way, experts split by expert parallel: plain TP8 cuts the 512-wide experts to 64 columns, below the checkpoint's group size 128). The kit uses the first TP x PP GPUs, or the ones listed in GPU_BDFS.
