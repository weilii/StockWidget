#!/usr/bin/env python3
"""Capture the real seven-symbol panel with live quotes and isolated storage."""
import argparse
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, default=root / "dist/StockWidget.app")
parser.add_argument("--output", type=Path, default=root / "docs/assets/stockwidget.png")
args = parser.parse_args()
app = args.app.resolve() / "Contents/MacOS/StockWidget"
destination = args.output.resolve()
destination.parent.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix="StockWidget-readme-") as state:
    result = subprocess.run([
        str(app), "--smoke-test", "--showcase", "--state-dir", state,
        "--capture", str(destination),
    ], cwd=root, check=False)
    raise SystemExit(result.returncode)
