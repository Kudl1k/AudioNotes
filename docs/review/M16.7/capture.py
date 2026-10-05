#!/usr/bin/env python3
"""Capture isolated DEBUG Local AI states; never downloads models or invokes native AI."""
import argparse
import subprocess
import time
from pathlib import Path

APP = "cz.stepankudlacek.audionotes.ios"
BASE = ["--performance-fixtures", "--ios-local-ai-review", "--ios-audio-review", "--ios-ux-review"]

def run(*args):
    subprocess.run(["xcrun", "simctl", *args], check=True, stdout=subprocess.DEVNULL)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("device")
    parser.add_argument("--app", required=True)
    parser.add_argument("--group", choices=["standard", "small", "ipad", "large"], default="standard")
    args = parser.parse_args()
    output = Path(__file__).parent / args.group
    output.mkdir(parents=True, exist_ok=True)
    booted = subprocess.run(["xcrun", "simctl", "list", "devices", "booted"], capture_output=True, text=True, check=True).stdout
    if args.device not in booted:
        run("boot", args.device)
    run("bootstatus", args.device, "-b")
    run("install", args.device, args.app)
    run("status_bar", args.device, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100")
    captures = [
        ("local-ai-settings", "light", []),
        ("transcription-models", "light", ["--ios-local-ai-section", "transcription"]),
        ("language-model", "dark", ["--ios-local-ai-section", "language"]),
        ("not-downloaded", "dark", ["--ios-local-ai-section", "transcription"]),
        ("downloading", "light", ["--ios-local-ai-section", "transcription", "--ios-local-ai-state", "downloading"]),
        ("ready", "dark", ["--ios-local-ai-section", "transcription", "--ios-local-ai-state", "ready"]),
        ("failed-download", "light", ["--ios-local-ai-section", "transcription", "--ios-local-ai-state", "failed"]),
        ("storage", "light", ["--ios-local-ai-section", "storage", "--ios-local-ai-state", "ready"]),
        ("on-device-transcription", "light", ["--ios-review-detail", "--ios-review-empty-transcript"]),
        ("missing-model-resolution", "dark", ["--ios-review-detail", "--ios-review-empty-transcript", "--ios-review-configuration"]),
        ("recording-chat-local-provider", "light", ["--ios-review-detail", "--ios-review-chat", "--ios-review-chat-history"]),
        ("project-chat-local-provider", "dark", ["--ios-project-knowledge-review", "--ios-project-review-chat", "--ios-project-chat-compact-review"]),
    ]
    if args.group != "standard":
        captures = [c for c in captures if c[0] in {"local-ai-settings", "language-model", "missing-model-resolution", "project-chat-local-provider"}]
    for name, appearance, extra in captures:
        run("ui", args.device, "appearance", appearance)
        run("ui", args.device, "content_size", "large")
        run("launch", "--terminate-running-process", args.device, APP, *BASE, *extra)
        time.sleep(7)
        run("io", args.device, "screenshot", str(output / f"{name}-{appearance}.png"))
        print(name, flush=True)
    for section in ("language", "transcription", "storage"):
        run("ui", args.device, "content_size", "accessibility-extra-extra-large")
        run("launch", "--terminate-running-process", args.device, APP, *BASE, "--ios-local-ai-section", section, "--ios-local-ai-state", "downloading")
        time.sleep(7)
        run("io", args.device, "screenshot", str(output / f"accessibility-{section}.png"))
        print("accessibility-" + section, flush=True)
    run("ui", args.device, "content_size", "large")
    run("ui", args.device, "appearance", "light")

if __name__ == "__main__":
    main()
