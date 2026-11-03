#!/usr/bin/env bash
# shellcheck disable=SC2016
set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY="${DRY:-0}"
if [ "$DRY" = 1 ]; then OUT="${OUT:-$KIT/out-dry}"; else OUT="${OUT:-$KIT/out}"; fi
CACHE="${CACHE:-$KIT/cache}"
VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai-xpu:v0.32.0}"
PATCHED_IMAGE="${PATCHED_IMAGE:-b60-vllm-pr457:local}"
BUILDER_IMAGE="${BUILDER_IMAGE:-b60-xpu-kernels-builder:local}"
KERNELS_REPO="${KERNELS_REPO:-https://github.com/vllm-project/vllm-xpu-kernels.git}"
MODEL="${MODEL:-Intel/Qwen3.6-35B-A3B-int4-mixed-AutoRound}"
MODEL_REV="${MODEL_REV:-65f69c73f17488236c85c85211f6ba28d7106157}"
MODEL_DIR="/models/$(basename "$MODEL")"
TP="${TP:-2}"
PP="${PP:-1}"
EP="${EP:-0}"
NGPU=$((TP * PP))
CONCS="${CONCS:-1 8 32 64}"
ARMS="${ARMS:-stock stock-eager}"
IN_LEN="${IN_LEN:-1024}"
OUT_LEN="${OUT_LEN:-1024}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-4096}"
MAX_SEQS="${MAX_SEQS:-64}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.90}"
CUDAGRAPH_MODE="${CUDAGRAPH_MODE:-PIECEWISE}"
CAPTURE_SIZES="${CAPTURE_SIZES:-[1,2,4,8,16,24,32,40,48,56,64]}"
AOT_DEVICES="${AOT_DEVICES:-bmg,bmg-g21-a0}"
PRIVILEGED="${PRIVILEGED:-0}"
T_PULL="${T_PULL:-5400}"
T_MODEL="${T_MODEL:-14400}"
T_SERVER="${T_SERVER:-3600}"
T_STALL="${T_STALL:-1500}"
T_BENCH="${T_BENCH:-3600}"
T_BUILD_IMG="${T_BUILD_IMG:-5400}"
T_BUILD="${T_BUILD:-14400}"
SERVE_NAME=b60-serve
HOST="$(hostname -s 2>/dev/null || hostname)"
TARBALL="$KIT/b60-results-$HOST-$(date +%Y%m%d).tar.gz"
[ "$DRY" = 1 ] && TARBALL="$KIT/b60-dryrun-$HOST-$(date +%Y%m%d).tar.gz"
SAMPLER_PIDS=()

mkdir -p "$OUT/inventory" "$OUT/arms" "$CACHE/models" "$CACHE/wheel"
exec > >(tee -a "$OUT/run.log") 2>&1
exec 3>&1

log() { printf '[%(%F %T)T] %s\n' -1 "$*" >&3; }
step() { printf '%s\t%s\t%s\n' "$(date +%FT%T)" "$1" "$2" >> "$OUT/steps.tsv"; }

run() {
    local secs="$1"; shift
    log "+ $*"
    [ "$DRY" = 1 ] && return 0
    timeout --kill-after=60 "$secs" "$@"
}

cap() {
    local file="$1"; shift
    { echo "\$ $*"; timeout 120 "$@" 2>&1; echo "[rc=$?]"; echo; } >> "$OUT/inventory/$file"
}

cleanup() {
    [ "${#SAMPLER_PIDS[@]}" -gt 0 ] && kill "${SAMPLER_PIDS[@]}" 2>/dev/null
    [ "$DRY" = 1 ] || docker rm -f "$SERVE_NAME" >/dev/null 2>&1
}
trap cleanup EXIT

finish() {
    log "summary"
    if command -v python3 >/dev/null; then
        python3 "$KIT/summarize.py" "$OUT" "$NGPU"
    elif [ "$DRY" != 1 ] && docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1; then
        docker run --rm -v "$OUT:/out" -v "$KIT/summarize.py:/s.py:ro" --entrypoint python3 "$VLLM_IMAGE" /s.py /out "$NGPU"
    fi
    cp "$KIT/run.sh" "$KIT/summarize.py" "$OUT/" 2>/dev/null
    sed -i -E 's/(Serial Number *:).*/\1 [redacted]/I; s/(Device Serial Number) [0-9a-f-]+/\1 [redacted]/I; s/^( *Username:).*/\1 [redacted]/' "$OUT"/inventory/*.txt 2>/dev/null
    tar -czf "$TARBALL" -C "$(dirname "$OUT")" "$(basename "$OUT")"
    log "DONE. Send this file: $TARBALL ($(du -h --apparent-size "$TARBALL" | cut -f1))"
}

inventory() {
    log "inventory"
    local f=system.txt
    : > "$OUT/inventory/$f"
    cap $f date -Is
    cap $f id
    cap $f uname -a
    cap $f cat /etc/os-release
    cap $f cat /proc/cmdline
    cap $f lscpu
    cap $f free -g
    cap $f numactl -H
    cap $f df -h "$KIT"
    cap $f docker version
    cap $f docker info
    : > "$OUT/inventory/gpu.txt"
    f=gpu.txt
    cap $f lspci -nn -d 8086:
    cap $f lspci -tv
    cap $f ls -l /dev/dri /dev/dri/by-path
    cap $f modinfo xe
    cap $f modinfo i915
    cap $f sh -c 'lsmod | grep -E "^(xe|i915) "'
    cap $f sh -c 'for d in /sys/class/drm/card*/device; do echo "$d $(cat $d/vendor $d/device 2>/dev/null | tr "\n" " ") driver=$(basename "$(readlink $d/driver)") numa=$(cat $d/numa_node 2>/dev/null) link=$(cat $d/current_link_speed 2>/dev/null)/x$(cat $d/current_link_width 2>/dev/null) max=$(cat $d/max_link_speed 2>/dev/null)/x$(cat $d/max_link_width 2>/dev/null)"; done'
    cap $f sh -c 'dmesg -T | grep -iE "xe |xe:|i915|guc|huc|gsc|dmc|firmware|pcie bus error|aer" | tail -400'
    cap $f sh -c 'cat /sys/kernel/debug/dri/*/gt*/uc/guc_info /sys/kernel/debug/dri/*/gt*/uc/huc_info 2>&1 | head -200'
    cap $f sh -c 'dpkg -l 2>/dev/null | grep -iE "level-zero|libze|intel-opencl|libigc|intel-igc|ocloc|xpu|oneapi|libigdgmm|intel-gpu|linux-firmware|intel-metrics" || rpm -qa 2>/dev/null | grep -iE "level-zero|intel|firmware"'
    cap $f sh -c 'ls /opt/intel/oneapi 2>/dev/null; cat /opt/intel/oneapi/*/latest/env/vars.sh 2>/dev/null | grep -m5 -i version'
    cap $f sycl-ls
    cap $f clinfo -l
    cap $f xpu-smi -v
    cap $f xpu-smi discovery
    cap $f xpu-smi topology -m
    for i in 0 1 2 3; do cap $f xpu-smi discovery -d $i; done
    cap $f igsc list-devices
    cap $f igsc fw version
    local bdf p
    : > "$OUT/inventory/lspci-vv.txt"
    for bdf in $(bmg_bdfs); do
        p="$(readlink -f "/sys/bus/pci/devices/$bdf")"
        while [ -n "$p" ] && [ "$p" != /sys/devices ]; do
            b="$(basename "$p")"
            [[ "$b" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] && cap lspci-vv.txt lspci -vv -s "$b"
            p="$(dirname "$p")"
        done
    done
    cap lspci-vv-all.txt lspci -vv
    grep -E "^\\$ lspci|LnkCap:|LnkSta:|Region|BAR|Resizable" "$OUT/inventory/lspci-vv.txt" > "$OUT/inventory/pcie-links.txt" 2>/dev/null
    step inventory ok
}

bmg_bdfs() {
    local d
    for d in /sys/bus/pci/devices/*; do
        [ "$(cat "$d/vendor" 2>/dev/null)" = 0x8086 ] || continue
        [ "$(cat "$d/class" 2>/dev/null | cut -c1-6)" = 0x0300 ] || [ "$(cat "$d/class" 2>/dev/null | cut -c1-6)" = 0x0380 ] || continue
        case "$(cat "$d/device")" in 0xe2*) basename "$d" ;; esac
    done
}

select_devices() {
    DEV_ARGS=(); SELECTED_BDFS=""
    local bdf n=0 node
    for bdf in ${GPU_BDFS:-$(bmg_bdfs)}; do
        [ "$n" -ge "$NGPU" ] && break
        if [ ! -d "/sys/bus/pci/devices/$bdf/drm" ]; then
            if [ -n "${GPU_BDFS:-}" ]; then
                log "FATAL: GPU_BDFS entry $bdf is not a PCI device with a DRM node (expected form 0000:18:00.0, see lspci -nn -d 8086:; is the xe driver bound?)"
                step devices FAIL; finish; exit 1
            fi
            log "skipping $bdf: no DRM node (driver not bound?)"; continue
        fi
        for node in /sys/bus/pci/devices/"$bdf"/drm/*; do
            node="$(basename "$node")"
            case "$node" in card*|renderD*) DEV_ARGS+=(--device "/dev/dri/$node") ;; esac
        done
        log "GPU $n: $bdf $(cat "/sys/bus/pci/devices/$bdf/device")"; SELECTED_BDFS="$SELECTED_BDFS $bdf"
        n=$((n + 1))
    done
    if [ "$n" -lt "$NGPU" ]; then
        log "FATAL: found $n usable Battlemage GPU(s) (PCI 8086:e2xx with a DRM node), need $NGPU (TP=$TP x PP=$PP). Set GPU_BDFS=\"0000:xx:00.0 0000:yy:00.0\" to pick devices explicitly"
        step devices FAIL
        [ "$DRY" = 1 ] || { finish; exit 1; }
        DEV_ARGS=(--device /dev/dri)
    fi
    [ -z "${GPU_BDFS:-}" ] && [ "$(bmg_bdfs | wc -l)" -gt "$NGPU" ] && log "WARNING: more than $NGPU Battlemage GPUs present; using the first $NGPU (lowest BDFs). Set GPU_BDFS to choose"
    if [ -d /dev/dri/by-path ]; then
        rm -rf "$OUT/dri-by-path"; mkdir -p "$OUT/dri-by-path"
        for bdf in $SELECTED_BDFS; do cp -P /dev/dri/by-path/pci-"$bdf"-* "$OUT/dri-by-path/" 2>/dev/null; done
        DEV_ARGS+=(-v "$OUT/dri-by-path:/dev/dri/by-path:ro")
    fi
    if [ "$PRIVILEGED" = 1 ]; then
        DEV_ARGS+=(--privileged)
        [ "$(bmg_bdfs | wc -l)" -gt "$NGPU" ] && log "WARNING: PRIVILEGED=1 exposes every GPU; vLLM takes the first $NGPU Level Zero devices regardless of GPU_BDFS (GPU_BDFS only labels the run)"
    fi
    log "docker device args: ${DEV_ARGS[*]}"
}

image_versions() {
    local img="$1" file="$2"
    [ "$DRY" = 1 ] && { log "+ docker run --rm $img (versions) > $file"; return 0; }
    timeout 600 docker run --rm "${DEV_ARGS[@]}" --entrypoint bash "$img" -c '
        python3 -c "import importlib.metadata as m
for p in [\"vllm\",\"vllm-xpu-kernels\",\"torch\",\"triton-xpu\",\"triton\",\"auto-round-lib\",\"transformers\",\"oneccl-bind-pt\",\"intel-sycl-rt\",\"intel-cmplr-lib-rt\",\"intel-opencl-rt\",\"mkl\"]:
    try: print(p, m.version(p))
    except Exception: print(p, \"-\")"
        python3 -c "import torch; print(\"xpu available\", torch.xpu.is_available(), \"count\", torch.xpu.device_count()); [print(i, torch.xpu.get_device_properties(i)) for i in range(torch.xpu.device_count())]"
        python3 -c "import vllm_xpu_kernels._C; print(\"vllm_xpu_kernels._C import ok\")"
        dpkg -l | grep -iE "level-zero|libze|intel-opencl|igc|ocloc|xpu-smi|libigdgmm"
        xpu-smi -v; xpu-smi discovery; sycl-ls
    ' > "$OUT/inventory/$file" 2>&1
    log "image versions -> $file: $(grep -E '^(vllm|vllm-xpu-kernels|torch) ' "$OUT/inventory/$file" | tr '\n' ' ')"
}

pkg_version() {
    local v
    v="$(grep -E "^$1 " "$OUT/inventory/$2" 2>/dev/null | awk '{print $2}')"
    [ -n "$v" ] && [ "$v" != - ] && echo "$v"
}

pull_image() {
    if [ "$DRY" != 1 ] && docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1; then
        log "image $VLLM_IMAGE present"
    else
        run "$T_PULL" docker pull "$VLLM_IMAGE" || { step pull FAIL; return 1; }
    fi
    [ "$DRY" = 1 ] || docker image inspect --format '{{.Id}} {{index .RepoDigests 0}}' "$VLLM_IMAGE" > "$OUT/inventory/image-stock-digest.txt"
    image_versions "$VLLM_IMAGE" image-stock.txt
    step pull ok
}

download_model() {
    if [ -f "$CACHE/models/$(basename "$MODEL")/.complete-$MODEL_REV" ]; then
        log "model present"; return 0
    fi
    local tok=()
    [ -n "${HF_TOKEN:-}" ] && tok=(-e HF_TOKEN)
    if run "$T_MODEL" docker run --rm "${tok[@]}" -e HF_HUB_ENABLE_HF_TRANSFER=0 -v "$CACHE/models:/models" --entrypoint bash "$VLLM_IMAGE" -c \
        "hf download $MODEL --revision $MODEL_REV --local-dir $MODEL_DIR || huggingface-cli download $MODEL --revision $MODEL_REV --local-dir $MODEL_DIR"; then
        [ "$DRY" = 1 ] || touch "$CACHE/models/$(basename "$MODEL")/.complete-$MODEL_REV"
        du -sh "$CACHE/models/$(basename "$MODEL")" 2>/dev/null
        step model ok
    else
        step model FAIL; return 1
    fi
}

start_sampler() {
    local dir="$1"
    SAMPLER_PIDS=()
    [ "$DRY" = 1 ] && return 0
    if command -v xpu-smi >/dev/null; then
        timeout "$T_BENCH" xpu-smi dump --device -1 --metrics 0,1,2,3,5,8,17,18,19,20 --interval 1 > "$dir/xpu-smi.csv" 2> "$dir/xpu-smi.err" &
    else
        timeout "$T_BENCH" docker exec "$SERVE_NAME" xpu-smi dump --device -1 --metrics 0,1,2,3,5,8,17,18,19,20 --interval 1 > "$dir/xpu-smi.csv" 2> "$dir/xpu-smi.err" &
    fi
    SAMPLER_PIDS+=("$!")
    (
        end=$((SECONDS + T_BENCH))
        while [ $SECONDS -lt $end ]; do
            line="$(date +%s.%N)"
            for f in /sys/class/drm/card[0-9]*/device/hwmon/hwmon*/energy*_input /sys/class/drm/card[0-9]*/device/hwmon/hwmon*/power*_input \
                     /sys/class/drm/card[0-9]*/device/tile0/gt0/freq0/act_freq; do
                [ -r "$f" ] && line="$line ${f#/sys/class/drm/}=$(cat "$f" 2>/dev/null)"
            done
            echo "$line"
            sleep 1
        done
    ) > "$dir/sysfs.txt" 2>/dev/null &
    SAMPLER_PIDS+=("$!")
}

stop_sampler() {
    [ "${#SAMPLER_PIDS[@]}" -gt 0 ] || return 0
    kill "${SAMPLER_PIDS[@]}" 2>/dev/null
    wait "${SAMPLER_PIDS[@]}" 2>/dev/null
    SAMPLER_PIDS=()
}

arm_complete() {
    local c
    for c in $CONCS; do [ -s "$OUT/arms/$1/c$c/result.json" ] || return 1; done
}

alive() { [ "$(docker inspect -f '{{.State.Running}}' "$SERVE_NAME" 2>/dev/null)" = true ]; }

start_server() {
    local img="$1" eager="$2" dir="$3"
    local mode=(--compilation-config "{\"cudagraph_mode\":\"$CUDAGRAPH_MODE\",\"cudagraph_capture_sizes\":$CAPTURE_SIZES}")
    [ "$eager" = 1 ] && mode=(--enforce-eager)
    [ "$DRY" = 1 ] || docker rm -f "$SERVE_NAME" >/dev/null 2>&1
    run 120 docker run -d --name "$SERVE_NAME" "${DEV_ARGS[@]}" --ipc=host \
        -e HF_HUB_OFFLINE=1 -e VLLM_LOGGING_LEVEL=INFO \
        -v "$CACHE/models:/models:ro" -v "$OUT:/out" \
        "$img" "$MODEL_DIR" --tensor-parallel-size "$TP" --pipeline-parallel-size "$PP" $([ "$EP" = 1 ] && echo --enable-expert-parallel) --max-model-len "$MAX_MODEL_LEN" \
        --max-num-seqs "$MAX_SEQS" --gpu-memory-utilization "$GPU_MEM_UTIL" --language-model-only \
        --host 127.0.0.1 --port 8000 "${mode[@]}" || return 1
    [ "$DRY" = 1 ] && return 0
    timeout $((T_SERVER + T_BENCH * 8)) docker logs -f "$SERVE_NAME" > "$dir/server.log" 2>&1 &
    local end=$((SECONDS + T_SERVER)) size=0 last=$SECONDS s
    while [ $SECONDS -lt $end ]; do
        alive || { log "server exited during startup"; return 1; }
        docker exec "$SERVE_NAME" curl -sf -m 5 http://127.0.0.1:8000/health >/dev/null 2>&1 && { log "server ready after $((SECONDS - end + T_SERVER)) s"; return 0; }
        s=$(stat -c %s "$dir/server.log" 2>/dev/null || echo 0)
        [ "$s" != "$size" ] && { size=$s; last=$SECONDS; }
        if [ $((SECONDS - last)) -ge "$T_STALL" ]; then
            log "server log silent for $T_STALL s during startup (hang?), giving up; last lines:"; tail -5 "$dir/server.log"
            return 1
        fi
        sleep 10
    done
    log "server not ready after $T_SERVER s"
    return 1
}

bench() {
    local c="$1" n="$2" dest="$3" extra=("${@:4}")
    run "$T_BENCH" docker exec "$SERVE_NAME" vllm bench serve --backend vllm --base-url http://127.0.0.1:8000 \
        --model "$MODEL_DIR" --dataset-name random --random-input-len "$IN_LEN" --random-output-len "$OUT_LEN" \
        --random-range-ratio 0 --ignore-eos --max-concurrency "$c" --num-prompts "$n" --seed 0 \
        --percentile-metrics ttft,tpot,itl,e2el --metric-percentiles 50,90,99 --disable-tqdm \
        --save-result --result-dir "$dest" --result-filename result.json "${extra[@]}"
}

run_arm() {
    local arm="$1" img="$2" eager="$3"
    local dir="$OUT/arms/$arm" c n todo=() rc=0
    mkdir -p "$dir"
    for c in $CONCS; do [ -s "$dir/c$c/result.json" ] || todo+=("$c"); done
    if [ "${#todo[@]}" -eq 0 ]; then log "arm $arm already complete"; return 0; fi
    case "$(cat "$dir/status" 2>/dev/null)" in
        crashed*|start-failed|timeout*) [ "${RETRY:-0}" = 1 ] || { log "arm $arm previously $(cat "$dir/status"), skipped (RETRY=1 to retry)"; return 1; } ;;
    esac
    log "=== arm $arm image=$img eager=$eager levels=${todo[*]}"
    echo running > "$dir/status"
    if ! start_server "$img" "$eager" "$dir"; then
        echo start-failed > "$dir/status"; step "arm-$arm" start-failed
        [ "$DRY" = 1 ] || docker rm -f "$SERVE_NAME" >/dev/null 2>&1
        return 1
    fi
    for c in "${todo[@]}"; do
        n=$(( c == 1 ? 16 : (4 * c > 32 ? 4 * c : 32) ))
        mkdir -p "$dir/c$c/warmup"
        OUT_LEN=64 bench "$c" "$c" "/out/arms/$arm/c$c/warmup" > "$dir/c$c/warmup/bench.log" 2>&1
        start_sampler "$dir/c$c"
        bench "$c" "$n" "/out/arms/$arm/c$c" > "$dir/c$c/bench.log" 2>&1
        rc=$?
        stop_sampler
        log "arm $arm c=$c prompts=$n rc=$rc $(grep -E 'Output token throughput|Failed requests' "$dir/c$c/bench.log" | tr -s ' ' | tr '\n' ' ')"
        if [ "$DRY" != 1 ] && ! alive; then
            log "server died at c=$c"; echo "crashed-at-c$c" > "$dir/status"; rc=99; break
        fi
        if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
            log "bench timeout at c=$c"; echo "timeout-at-c$c" > "$dir/status"; break
        fi
    done
    [ "$DRY" = 1 ] || docker exec "$SERVE_NAME" curl -s -m 10 http://127.0.0.1:8000/metrics > "$dir/metrics.txt" 2>/dev/null
    [ "$(cat "$dir/status")" = running ] && echo ok > "$dir/status"
    [ "$DRY" = 1 ] || { docker stop -t 30 "$SERVE_NAME" >/dev/null 2>&1; docker rm -f "$SERVE_NAME" >/dev/null 2>&1; }
    dmesg -T 2>/dev/null | grep -iE '\bxe\b|i915|drm|pci|gpu|guc|huc|oom|out of memory|segfault|killed process|hung|reset|aer|fault' | tail -300 > "$dir/dmesg-tail.txt"
    step "arm-$arm" "$(cat "$dir/status")"
    [ "$(cat "$dir/status")" = ok ]
}

build_patched() {
    if [ "$DRY" != 1 ] && docker image inspect "$PATCHED_IMAGE" >/dev/null 2>&1; then
        log "patched image present"; image_versions "$PATCHED_IMAGE" image-pr457.txt; return 0
    fi
    local kver tver ref="" src="$CACHE/vllm-xpu-kernels" jobs mem
    kver="$(pkg_version vllm-xpu-kernels image-stock.txt)"; kver="${kver:-0.1.15.4}"
    tver="$(pkg_version torch image-stock.txt)"; tver="${tver:-2.14.0+xpu}"
    log "stock kernels $kver, torch $tver"
    git ls-remote "$KERNELS_REPO" refs/pull/457/head > "$OUT/inventory/pr457-head.txt" 2>&1
    for r in "v$kver" "$kver" "release/$kver" "release/v$kver"; do
        if git ls-remote --exit-code "$KERNELS_REPO" "refs/tags/$r" "refs/heads/$r" >/dev/null 2>&1; then ref="$r"; break; fi
    done
    [ -z "$ref" ] && { log "WARNING: no ref for kernels $kver, using main"; ref=main; }
    log "kernels source ref $ref"
    echo "$ref" > "$OUT/inventory/pr457-source-ref.txt"
    if [ ! -d "$src/.git" ] || [ "$(cat "$src/.b60ref" 2>/dev/null)" != "$ref" ]; then
        [ "$DRY" = 1 ] || rm -rf "$src"
        run 900 git clone --depth 1 --branch "$ref" "$KERNELS_REPO" "$src" || return 1
        [ "$DRY" = 1 ] || echo "$ref" > "$src/.b60ref"
    fi
    run "$T_BUILD_IMG" docker build -f "$src/Dockerfile.xpu" -t "$BUILDER_IMAGE" "$src" > "$OUT/build-builder-image.log" 2>&1 || { log "builder image failed, see build-builder-image.log"; return 1; }
    mem=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1048576 ))
    jobs=$(( mem / 8 )); [ "$jobs" -gt "$(nproc)" ] && jobs=$(nproc); [ "$jobs" -lt 1 ] && jobs=1
    log "building kernels wheel MAX_JOBS=$jobs AOT=$AOT_DEVICES (long step)"
    [ "$DRY" = 1 ] || rm -f "$CACHE/wheel/"*.whl
    run "$T_BUILD" docker run --rm -v "$src:/src:ro" -v "$([ -d "$KIT/patches" ] && echo "$KIT/patches" || echo "$KIT"):/patches:ro" -v "$CACHE/wheel:/wheel" \
        -e MAX_JOBS="$jobs" -e VLLM_XPU_AOT_DEVICES="$AOT_DEVICES" -e VLLM_XPU_XE2_AOT_DEVICES="$AOT_DEVICES" \
        -e VLLM_VERSION_OVERRIDE="$kver+pr457" -e TORCH_VER="$tver" --entrypoint bash "$BUILDER_IMAGE" -c '
        set -e
        if [ -f /opt/intel/oneapi/setvars.sh ]; then source /opt/intel/oneapi/setvars.sh --force >/dev/null 2>&1 || true; fi
        cp -a /src /build && cd /build
        git config --global --add safe.directory /build
        git apply -v /patches/pr457-rebased.diff || git apply -v /patches/pr457-original.diff
        grep -n "group_id += group_range" csrc/xpu/grouped_gemm/xe_2/grouped_gemm_xe2.hpp
        git diff --stat
        uv pip install "cmake>=3.26" ninja "packaging>=24.2" "setuptools>=77.0.3,<80.0.0" "setuptools-scm>=8" "torch==${TORCH_VER}" wheel regex jinja2 build
        python setup.py bdist_wheel --dist-dir /wheel --py-limited-api=cp38
        ls -l /wheel
    ' > "$OUT/build-kernels.log" 2>&1 || { log "kernels build failed, see build-kernels.log"; tail -30 "$OUT/build-kernels.log"; return 1; }
    printf 'FROM %s\nCOPY *.whl /tmp/\nRUN (uv pip install --no-deps --force-reinstall /tmp/*.whl || python3 -m pip install --no-deps --force-reinstall /tmp/*.whl) && rm /tmp/*.whl\n' "$VLLM_IMAGE" > "$CACHE/wheel/Dockerfile"
    run 1800 docker build -t "$PATCHED_IMAGE" "$CACHE/wheel" > "$OUT/build-patched-image.log" 2>&1 || { log "patched image failed"; return 1; }
    image_versions "$PATCHED_IMAGE" image-pr457.txt
    [ "$DRY" = 1 ] || grep -q "pr457" "$OUT/inventory/image-pr457.txt" || { log "patched image does not report pr457 kernels"; return 1; }
    step build-pr457 ok
}

log "B60 kit start host=$HOST DRY=$DRY image=$VLLM_IMAGE model=$MODEL@$MODEL_REV arms=$ARMS concs=$CONCS TP=$TP PP=$PP EP=$EP"
[ "$(id -u)" = 0 ] || log "WARNING: not root; lspci -vv capabilities, dmesg and power counters may be missing (use sudo)"
avail=$(df -BG --output=avail "$KIT" | tail -1 | tr -dc 0-9)
[ "${avail:-0}" -lt 30 ] && log "WARNING: only ${avail}G free in $KIT, about 30G needed for the model cache (pr457 arm: 50G)"
inventory
if [ "$DRY" != 1 ] && ! docker info >/dev/null 2>&1; then
    log "FATAL: docker not usable (install Docker or run with sudo)"; step docker FAIL; finish; exit 1
fi
droot=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)
if [ -d "$droot" ]; then
    davail=$(df -BG --output=avail "$droot" | tail -1 | tr -dc 0-9)
    [ "${davail:-0}" -lt 20 ] && log "WARNING: only ${davail}G free in Docker root $droot, about 20G needed for the image (pr457 arm: 40G)"
fi
select_devices
pull_image || { finish; exit 1; }
download_model || { finish; exit 1; }
for arm in $ARMS; do
    case "$arm" in
        stock)
            run_arm stock "$VLLM_IMAGE" 0 || CAPTURE_SIZES='[1,2,4,8]' run_arm stock-cap8 "$VLLM_IMAGE" 0 ;;
        stock-eager)
            run_arm stock-eager "$VLLM_IMAGE" 1 ;;
        pr457)
            if arm_complete pr457 || build_patched; then run_arm pr457 "$PATCHED_IMAGE" 0; else step build-pr457 FAIL; fi ;;
        *) log "unknown arm $arm" ;;
    esac
done
finish
