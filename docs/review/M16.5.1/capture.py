#!/usr/bin/env python3
"""Capture actual DEBUG offline routes; APP must be a built Simulator AudioNotes.app."""
import argparse
import subprocess
import time
from pathlib import Path

BUNDLE = 'cz.stepankudlacek.audionotes.ios'
DEVICES = {
    'standard': '586131BF-8D5E-4EEA-923E-70500D46AB7C',
    'small': 'D19FC8E2-F95E-4FFE-901A-F52E23EE5BCF',
    'large': '5B7B0210-4C4C-4812-9C32-53C84683C040',
    'ipad': '652D97EB-6AE6-4A23-A757-2353BE2EDFBD',
}

def sim(*args, check=True):
    return subprocess.run(['xcrun', 'simctl', *args], check=check, capture_output=True, text=True)

def capture(device, name, flags, appearance='dark', size='large', contrast=False):
    if ONLY and name not in ONLY:
        return
    sim('ui', device, 'appearance', appearance)
    sim('ui', device, 'content_size', size)
    sim('ui', device, 'increase_contrast', 'enabled' if contrast else 'disabled')
    sim('status_bar', device, 'override', '--time', '9:41', '--batteryState', 'charged', '--batteryLevel', '100')
    container = Path(sim('get_app_container', device, BUNDLE, 'data').stdout.strip())
    marker = container / 'tmp/AudioNotes-M11-Fixtures/ios-ux-review-ready'
    marker.unlink(missing_ok=True)
    sim('launch', '--terminate-running-process', device, BUNDLE,
        '--performance-fixtures', '--ios-audio-review', *flags)
    deadline = time.monotonic() + 45
    while not marker.exists():
        if time.monotonic() > deadline:
            raise RuntimeError(f'Offline fixture failed to become ready: {name}')
        time.sleep(.2)
    time.sleep(SETTLE)  # Native queries, cold-start layout, Markdown and sheet transitions.
    sim('io', device, 'screenshot', str(OUTPUT / (name + '.png')))
    print(name, flush=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    parser.add_argument('--group', choices=DEVICES, required=True)
    parser.add_argument('--settle', type=float, default=8, help='Seconds to allow native rendering after fixture preparation')
    parser.add_argument('--only', nargs='+', help='Recapture named surfaces after review corrections')
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parent)
    args = parser.parse_args()
    SETTLE = args.settle
    ONLY = set(args.only or [])
    OUTPUT = args.output
    OUTPUT.mkdir(parents=True, exist_ok=True)
    device = DEVICES[args.group]
    sim('boot', device, check=False)
    sim('bootstatus', device, '-b')
    sim('install', device, str(args.app))
    ux = ['--ios-ux-review']
    detail = ux + ['--ios-review-detail']
    settings = ux + ['--ios-review-settings', '--ios-review-connected-accounts']
    if args.group == 'standard':
        capture(device, 'recording-transcript-dark', detail)
        capture(device, 'recording-transcript-light', detail, 'light')
        capture(device, 'transcription-empty', detail + ['--ios-review-empty-transcript'])
        capture(device, 'transcription-settings', detail + ['--ios-review-empty-transcript', '--ios-review-configuration'])
        capture(device, 'summary', detail + ['--ios-review-summary'])
        capture(device, 'summary-empty', detail + ['--ios-review-summary', '--ios-review-empty-summary'], 'light')
        capture(device, 'recording-chat', detail + ['--ios-review-chat', '--ios-review-chat-history'])
        capture(device, 'library', ux + ['--ios-review-projects'], 'light')
        capture(device, 'project-detail', ux + ['--ios-review-projects', '--ios-review-project'])
        capture(device, 'settings-root', settings, 'light')
        capture(device, 'chatgpt-account', settings + ['--ios-review-chatgpt'])
        capture(device, 'gemini-account', settings + ['--ios-review-gemini'], 'light')
        capture(device, 'transcript-final-segment', detail + ['--ios-review-transcript-end'], 'light')
        capture(device, 'recording-reduce-transparency', detail + ['--ios-review-reduce-transparency'], 'light')
        capture(device, 'recording-increased-contrast', detail, contrast=True)
        capture(device, 'chat-reduce-transparency', detail + ['--ios-review-chat', '--ios-review-chat-history', '--ios-review-reduce-transparency'], 'light')
        capture(device, 'long-transcript-6000', ['--ios-review-detail'])
        capture(device, 'long-chat-250', detail + ['--ios-review-chat', '--ios-review-long-chat'])
        capture(device, 'large-library-401', ux + ['--ios-review-large-library'], 'light')
        capture(device, 'move-to-project', detail + ['--ios-review-projects', '--ios-review-move'])
        capture(device, 'new-project', ux + ['--ios-review-new-project'], 'light')
    elif args.group == 'small':
        capture(device, 'small-iphone-detail', detail + ['--ios-review-long-title'], 'light')
        capture(device, 'small-iphone-accessibility-detail', detail + ['--ios-review-long-title'], 'light', 'accessibility-extra-large')
        capture(device, 'small-iphone-empty', detail + ['--ios-review-empty-transcript'], 'light')
        capture(device, 'small-iphone-chat', detail + ['--ios-review-chat', '--ios-review-chat-history'], 'light')
        capture(device, 'small-iphone-accessibility-account', settings + ['--ios-review-chatgpt'], 'light', 'accessibility-extra-large')
    elif args.group == 'large':
        capture(device, 'large-iphone-detail-dark', detail + ['--ios-review-long-title'])
        capture(device, 'large-iphone-detail-light', detail + ['--ios-review-long-title'], 'light')
    else:
        capture(device, 'ipad-detail-dark', detail)
        capture(device, 'ipad-detail-light', detail, 'light')
        capture(device, 'ipad-library-dark', ux + ['--ios-review-projects'])
        capture(device, 'ipad-library-light', ux + ['--ios-review-projects'], 'light')
        capture(device, 'ipad-transcription-settings', detail + ['--ios-review-configuration'])
        capture(device, 'ipad-chat', detail + ['--ios-review-chat', '--ios-review-chat-history'], 'light')
    sim('ui', device, 'content_size', 'large')
    sim('ui', device, 'increase_contrast', 'disabled')
    sim('status_bar', device, 'clear')
