#!/usr/bin/env python3
"""Exercise only StockWidget's own windows, with temporary storage and real cached quotes."""
import json
import argparse
from pathlib import Path
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, default=root / "dist/StockWidget.app")
args = parser.parse_args()
app = args.app / "Contents/MacOS/StockWidget"
output = root / "output"
output.mkdir(exist_ok=True)


def sample(pid):
    raw = subprocess.check_output(["ps", "-p", str(pid), "-o", "rss=,time=,pcpu="], text=True).strip().split()
    duration = 0.0
    for part in raw[1].split(":"):
        duration = duration * 60 + float(part)
    return {"rss_kib": int(raw[0]), "cpu_seconds": duration, "reported_cpu_percent": float(raw[2])}


with tempfile.TemporaryDirectory(prefix="StockWidget-ui-") as state:
    baseline = [str(app), "--smoke-test", "--state-dir", state]
    command = baseline + ["--exercise-store", "--exercise-compact", "--exercise-desktop", "--exercise-drag", "--capture", str(output / "watchlist.png"), "--hold-seconds", "8"]
    process = subprocess.Popen(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    lines = []
    for line in process.stdout:
        lines.append(line)
        print(line, end="", flush=True)
        if line.startswith("UI_SMOKE "):
            time.sleep(1)
            first = sample(process.pid)
            start = time.monotonic()
            time.sleep(3)
            second = sample(process.pid)
            elapsed = time.monotonic() - start
            metrics = {"initial": first, "idle": second, "idle_sample_seconds": elapsed,
                       "idle_cpu_percent_from_time_delta": round((second["cpu_seconds"] - first["cpu_seconds"]) / elapsed * 100, 2),
                       "note": "One short local sample after loading 5 live symbols; RSS is not total energy or full memory footprint."}
            (output / "resource-sample.json").write_text(json.dumps(metrics, indent=2))
            print("RESOURCE_SAMPLE " + json.dumps(metrics), flush=True)
            break
    rest, _ = process.communicate(timeout=45)
    print(rest, end="", flush=True)
    if process.returncode != 0:
        raise SystemExit(process.returncode)
    for screen in ["settings", "search", "detail", "empty", "offline"]:
        command = baseline + ["--cached-ui", "--screen", screen, "--capture", str(output / f"{screen}.png")]
        if screen == "settings":
            command += ["--chinese"]
        result = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)
        print(f"SCREEN {screen}\n{result.stdout}", flush=True)
        if result.returncode != 0:
            raise SystemExit(result.returncode)
print("PASS: native window, view states, Chinese settings, ordering, deletion, persistence, always-on-top, cached/offline display")
