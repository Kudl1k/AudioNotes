#!/usr/bin/env python3
"""Capture deterministic DEBUG iOS Project Sources/Chat screens from an installed app."""
import argparse
import subprocess
import time
from pathlib import Path


APP_ID = "cz.stepankudlacek.audionotes.ios"
BASE = ["--performance-fixtures", "--ios-project-knowledge-review"]


def run(*args: str) -> None:
    subprocess.run(["xcrun", "simctl", *args], check=True, stdout=subprocess.DEVNULL)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("device", help="Simulator UDID")
    parser.add_argument("--output", type=Path, default=Path(__file__).parent)
    parser.add_argument("--settle", type=float, default=8)
    parser.add_argument("--group", choices=("iphone", "ipad", "all"), default="all")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    booted = subprocess.run(["xcrun", "simctl", "list", "devices", "booted"], capture_output=True, text=True, check=True).stdout
    if args.device not in booted:
        run("boot", args.device)
    run("bootstatus", args.device, "-b")
    run("status_bar", args.device, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100")
    app = subprocess.run(["xcrun", "simctl", "get_app_container", args.device, APP_ID, "app"], capture_output=True, text=True)
    if app.returncode:
        raise SystemExit("Install AudioNotesiOS Debug on this Simulator before capturing.")

    captures = [
        ("project-recordings", "dark", BASE),
        ("sources-empty", "light", BASE + ["--ios-project-empty-sources", "--ios-project-empty-chat", "--ios-project-review-sources"]),
        ("sources-populated", "light", BASE + ["--ios-project-review-sources"]),
        ("project-import-progress", "light", BASE + ["--ios-project-import-progress", "--ios-project-review-sources"]),
        ("source-processing", "dark", BASE + ["--ios-project-processing-state", "--ios-project-review-sources"]),
        ("source-failure", "light", BASE + ["--ios-project-processing-failure", "--ios-project-review-sources"]),
        ("pdf-viewer", "light", BASE + ["--ios-project-review-sources", "--ios-project-review-pdf"]),
        ("image-viewer", "dark", BASE + ["--ios-project-review-sources", "--ios-project-review-image"]),
        ("markdown-viewer", "light", BASE + ["--ios-project-review-sources", "--ios-project-review-markdown"]),
        ("project-chat-empty", "dark", BASE + ["--ios-project-empty-chat", "--ios-project-review-chat"]),
        ("project-chat-recording-citation", "light", BASE + ["--ios-project-recording-citation", "--ios-project-review-chat"]),
        ("project-chat-pdf-citation", "light", BASE + ["--ios-project-pdf-citation", "--ios-project-review-chat"]),
        ("project-chat-mixed-citations", "dark", BASE + ["--ios-project-review-chat"]),
    ]
    if args.group == "ipad":
        captures = [item for item in captures if item[0] in {"project-recordings", "sources-populated", "project-chat-mixed-citations"}]
        captures = [(name, appearance, launch_args + ["--ios-project-chat-compact-review"] if name == "project-chat-mixed-citations" else launch_args) for name, appearance, launch_args in captures]
    for name, appearance, launch_args in captures:
        run("ui", args.device, "appearance", appearance)
        run("ui", args.device, "content_size", "large")
        run("launch", "--terminate-running-process", args.device, APP_ID, *launch_args)
        time.sleep(args.settle)
        run("io", args.device, "screenshot", str(args.output / f"{name}-{appearance}.png"))

    # An explicit accessibility-size capture checks the adaptive workspace selector.
    if args.group != "ipad":
        run("ui", args.device, "content_size", "accessibility-extra-extra-large")
        run("launch", "--terminate-running-process", args.device, APP_ID, *(BASE + ["--ios-project-review-chat"]))
        time.sleep(args.settle)
        run("io", args.device, "screenshot", str(args.output / "project-chat-accessibility.png"))
    run("ui", args.device, "content_size", "large")
    run("ui", args.device, "appearance", "light")


if __name__ == "__main__":
    main()
