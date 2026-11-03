#!/usr/bin/env python3
import csv
import json
import re
import sys
from pathlib import Path

out = Path(sys.argv[1] if len(sys.argv) > 1 else "out")
tp = int(sys.argv[2]) if len(sys.argv) > 2 else 2


def mean(xs):
    return sum(xs) / len(xs) if xs else None


def smi_stats(path):
    if not path.exists():
        return {}
    rows = [r for r in csv.reader(path.open(errors="replace")) if r]
    if not rows:
        return {}
    head = [h.strip() for h in rows[0]]
    col = {h: i for i, h in enumerate(head)}
    dev_i = next((i for h, i in col.items() if "deviceid" in h.lower().replace(" ", "").replace("_", "")), None)
    want = {"power_w": ("Power (W)", "power.draw"), "freq_mhz": ("Frequency", "clocks."), "mem_used_mib": ("Memory Used", "memory.used"), "temp_c": ("Core Temperature", "temperature.")}
    acc = {}
    for r in rows[1:]:
        dev = r[dev_i].strip() if dev_i is not None and dev_i < len(r) else "?"
        for key, pat in want.items():
            i = next((i for h, i in col.items() if any(x.lower() in h.lower() for x in pat)), None)
            if i is None or i >= len(r):
                continue
            try:
                v = float(r[i])
            except ValueError:
                continue
            acc.setdefault((dev, key), []).append(v)
    res = {}
    for (dev, key), vs in acc.items():
        res.setdefault(key, {})[dev] = (max(vs) if key == "mem_used_mib" else mean(vs))
    return res


def sysfs_power(path):
    if not path.exists():
        return {}
    pts = []
    for line in path.read_text(errors="replace").splitlines():
        f = line.split()
        if len(f) < 2:
            continue
        kv = dict(x.split("=", 1) for x in f[1:] if "=" in x)
        e = {k.split("/")[0]: float(v) for k, v in kv.items() if k.endswith("/energy1_input") and v.replace(".", "", 1).isdigit()}
        if e:
            pts.append((float(f[0]), e))
    if len(pts) < 2:
        return {}
    (t0, e0), (t1, e1) = pts[0], pts[-1]
    return {c: (e1[c] - e0[c]) / 1e6 / (t1 - t0) for c in e1 if c in e0 and t1 > t0}


def fmt(v, nd=1):
    return "" if v is None else f"{v:.{nd}f}"


rows = []
for arm_dir in sorted(p for p in (out / "arms").glob("*") if p.is_dir()):
    status = (arm_dir / "status").read_text().strip() if (arm_dir / "status").exists() else "unknown"
    log = arm_dir / "server.log"
    errs = ""
    kv = ""
    if log.exists():
        txt = log.read_text(errors="replace")
        hits = sorted(set(re.findall(r"DEVICE_LOST|CCL_ERROR|onecclCommInitRank failed|UR_RESULT_ERROR_\w+|ZE_RESULT_ERROR_\w+|out of memory|OutOfMemory|Traceback|EngineDeadError|page fault", txt)))
        errs = " ".join(hits)
        m = re.search(r"KV cache size: ([\d,]+) tokens, Maximum concurrency for [\d,]+ tokens per request: ([\d.]+)x", txt)
        if m:
            kv = f"{m.group(1).replace(',', '')} tok, {m.group(2)}x"
    preempt = None
    met = arm_dir / "metrics.txt"
    if met.exists():
        m = re.search(r"^vllm:num_preemptions_total\S* ([\d.e+]+)", met.read_text(errors="replace"), re.M)
        if m:
            preempt = int(float(m.group(1)))
    levels = sorted(arm_dir.glob("c*"), key=lambda p: int(p.name[1:]) if p.name[1:].isdigit() else 0)
    if not levels:
        rows.append({"arm": arm_dir.name, "status": status, "server_errors": errs})
    for lv in levels:
        if not lv.is_dir() or not lv.name[1:].isdigit():
            continue
        row = {"arm": arm_dir.name, "status": status, "concurrency": int(lv.name[1:]), "server_errors": errs,
               "kv_cache": kv, "preemptions_arm_total": preempt}
        res = lv / "result.json"
        if res.exists():
            try:
                d = json.loads(res.read_text())
            except json.JSONDecodeError:
                d = {}
            otp = d.get("output_throughput")
            row.update({
                "prompts": d.get("num_prompts"),
                "completed": d.get("completed"),
                "failed": d.get("failed"),
                "duration_s": d.get("duration"),
                "output_tok_s": otp,
                "per_gpu_tok_s": otp / tp if otp else None,
                "ttft_med_ms": d.get("median_ttft_ms"),
                "ttft_p99_ms": d.get("p99_ttft_ms"),
                "tpot_med_ms": d.get("median_tpot_ms"),
                "tpot_p99_ms": d.get("p99_tpot_ms"),
            })
        else:
            row["failed"] = "no-result"
        st = smi_stats(lv / "xpu-smi.csv")
        p = st.get("power_w", {}) or sysfs_power(lv / "sysfs.txt")
        row["power_w_per_gpu"] = " ".join(f"{k}:{v:.0f}" for k, v in sorted(p.items()))
        row["freq_mhz_per_gpu"] = " ".join(f"{k}:{v:.0f}" for k, v in sorted(st.get("freq_mhz", {}).items()))
        row["mem_used_mib_max"] = " ".join(f"{k}:{v:.0f}" for k, v in sorted(st.get("mem_used_mib", {}).items()))
        busy = sorted(p.values(), reverse=True)[:tp]
        tot_p = sum(busy) if busy else None
        if tot_p and row.get("output_tok_s"):
            row["tok_per_joule"] = row["output_tok_s"] / tot_p
        rows.append(row)

cols = ["arm", "status", "concurrency", "prompts", "completed", "failed", "duration_s", "output_tok_s", "per_gpu_tok_s",
        "ttft_med_ms", "ttft_p99_ms", "tpot_med_ms", "tpot_p99_ms", "power_w_per_gpu", "freq_mhz_per_gpu",
        "mem_used_mib_max", "tok_per_joule", "kv_cache", "preemptions_arm_total", "server_errors"]
with (out / "summary.csv").open("w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
    w.writeheader()
    w.writerows(rows)

lines = [f"{'arm':<14}{'status':<22}{'c':>4}{'ok/fail':>12}{'out tok/s':>11}{'tok/s/GPU':>11}{'TTFT med/p99 ms':>20}{'TPOT med/p99 ms':>18}  power W/GPU"]
for r in rows:
    okf = f"{r.get('completed', '')}/{r.get('failed', '')}" if "concurrency" in r else ""
    ttft = f"{fmt(r.get('ttft_med_ms'), 0)}/{fmt(r.get('ttft_p99_ms'), 0)}" if r.get("ttft_med_ms") is not None else ""
    tpot = f"{fmt(r.get('tpot_med_ms'))}/{fmt(r.get('tpot_p99_ms'))}" if r.get("tpot_med_ms") is not None else ""
    lines.append(f"{r['arm']:<14}{r['status'][:21]:<22}{r.get('concurrency', ''):>4}{okf:>12}{fmt(r.get('output_tok_s')):>11}"
                 f"{fmt(r.get('per_gpu_tok_s')):>11}{ttft:>20}{tpot:>18}  {r.get('power_w_per_gpu', '')}")
best = max((r.get("per_gpu_tok_s") or 0 for r in rows if r.get("concurrency") in (32, 64) and not r.get("failed")), default=0)
lines.append("")
lines.append(f"best per-GPU tok/s at c32/c64 without failures: {best:.1f}")
lines.append(f"tok_per_joule uses the {tp} highest-power devices (xpu-smi, else hwmon energy1 = card), others assumed idle")
if any("cap8" in r["arm"] for r in rows):
    lines.append("stock-cap8: graphs captured only for batch<=8; decode at c32/c64 runs uncaptured (compiled, no graph)")
kvs = sorted({r['arm'] + ': ' + r['kv_cache'] + (f", preemptions {r['preemptions_arm_total']}" if r.get('preemptions_arm_total') is not None else '') for r in rows if r.get('kv_cache')})
lines += ["KV cache " + k for k in kvs]
errs = sorted({r['arm'] + ': ' + r['server_errors'] for r in rows if r.get("server_errors")})
lines += ["server log errors: " + e for e in errs]
text = "\n".join(lines) + "\n"
(out / "summary.txt").write_text(text)
print(text, end="")
