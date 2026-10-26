#!/usr/bin/env python3
"""Run offline sync scenarios using Swift 6 or an already downloaded Docker image."""

import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

IMAGE = "swift:6.0.3@sha256:f19aea3f9a889df5884e1186e60be74869613477d99656b598c115a4b91af8a1"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, help="Optional baseline AppModel.swift")
    parser.add_argument("--docker", action="store_true", help="Use Docker even when swiftc exists")
    parser.add_argument("--suite", choices=("app", "engine", "stress"), default="app")
    parser.add_argument("--engine", type=Path, help="Optional baseline SyncEngine.swift")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="healthmi-virtual-") as directory:
        prepare = [sys.executable, str(here / "prepare.py"), directory, "--suite", args.suite]
        if args.model:
            prepare += ["--model", str(args.model.resolve())]
        if args.engine:
            prepare += ["--engine", str(args.engine.resolve())]
        subprocess.run(prepare, check=True)
        if shutil.which("swiftc") and not args.docker:
            binary = str(Path(directory) / "virtual-sync")
            sources = sorted(str(p) for p in Path(directory).glob("*.swift"))
            subprocess.run(["swiftc", "-swift-version", "6", "-strict-concurrency=complete",
                            "-parse-as-library", *sources, "-o", binary], check=True, timeout=120)
            subprocess.run([binary], check=True, timeout=30)
        else:
            if not shutil.which("docker"):
                parser.error("Swift 6 or Docker with the documented Swift image is required")
            # No pull, network, credentials, device or repository write access in the container.
            subprocess.run([
                "docker", "run", "--rm", "--pull", "never", "--network", "none",
                "--mount", f"type=bind,src={directory},dst=/input,readonly", IMAGE,
                "sh", "-c", "swiftc -swift-version 6 -strict-concurrency=complete "
                "-parse-as-library /input/*.swift -o /tmp/virtual-sync "
                "&& timeout 30 /tmp/virtual-sync",
            ], check=True, timeout=180)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
