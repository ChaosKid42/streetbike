#!/usr/bin/env python3
"""Capture the gameplay GIF from a headless VICE run.

The script patches a throwaway copy of ``src/streetbike.asm`` in ``build/``,
assembles it with ACME, drives ``x64sc`` through the monitor to save one
PNG per frame, and encodes a segment of those frames into
``screenshots/gameplay.gif`` with ffmpeg.

Run it from anywhere; all paths are resolved relative to the repository root.
Requires ``acme``, ``x64sc`` and ``ffmpeg`` on ``PATH``.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "src" / "streetbike.asm"
BUILD = ROOT / "build"
TEST_ASM = BUILD / "test.asm"
TEST_PRG = BUILD / "test.prg"
LABELS = BUILD / "test.labels"
MONITOR = BUILD / "mon.txt"
FRAMES = BUILD / "frames"

# The game waits for fire on the title screen. Start it immediately and use
# $50/$51 (unused zero page) as a 16-bit auto-jump countdown.
AUTO_START = """\
    lda #<{first_jump}
    sta $50
    lda #>{first_jump}
    sta $51
    jsr start_game
"""

# Force the fire bit low for one frame whenever the countdown expires. The
# jump schedule is tuned to the current obstacle sequence; see AGENTS.md.
AUTO_JUMP = """\
    lda $50
    ora $51
    beq .do_jump
    lda $50
    bne .dec_lo
    dec $51
.dec_lo:
    dec $50
    jmp .autotest
.do_jump:
    lda #<{jump_interval}
    sta $50
    lda #>{jump_interval}
    sta $51
    lda zp_joy
    and #%11101111
    sta zp_joy
.autotest:
"""


def run(command: list[str], *, cwd: Path = ROOT) -> None:
    print("+", " ".join(command))
    subprocess.run(command, cwd=cwd, check=True)


def patch_source(first_jump: int, jump_interval: int) -> str:
    source = SOURCE.read_text(encoding="utf-8")

    if "build/streetbike.prg" not in source:
        sys.exit(f"{SOURCE}: could not find the output path to redirect")
    source = source.replace("build/streetbike.prg", "build/test.prg", 1)

    if "    cli\n" not in source:
        sys.exit(f"{SOURCE}: could not find the 'cli' init line")
    source = source.replace(
        "    cli\n",
        "    cli\n" + AUTO_START.format(first_jump=first_jump),
        1,
    )

    if "    jsr read_joystick\n" not in source:
        sys.exit(f"{SOURCE}: could not find the read_joystick call")
    source = source.replace(
        "    jsr read_joystick\n",
        "    jsr read_joystick\n" + AUTO_JUMP.format(jump_interval=jump_interval),
        1,
    )

    return source


def main_loop_address() -> str:
    text = LABELS.read_text(encoding="utf-8")
    match = re.search(r"^al C:([0-9a-fA-F]+) \.main_loop$", text, re.MULTILINE)
    if not match:
        sys.exit(f"{LABELS}: could not find the main_loop label")
    return match.group(1).upper()


def write_monitor_commands(address: str, frame_count: int) -> None:
    lines = [f"break C:{address}", "g"]
    for index in range(frame_count):
        lines.append(f'screenshot "build/frames/f{index:03d}.png" 2')
        lines.append("g")
    lines.append("quit")
    MONITOR.write_text("\n".join(lines) + "\n", encoding="utf-8")


def capture_frames(frame_count: int, jump_first: int, jump_interval: int) -> None:
    if FRAMES.exists():
        shutil.rmtree(FRAMES)
    FRAMES.mkdir(parents=True)

    TEST_ASM.write_text(
        patch_source(jump_first, jump_interval),
        encoding="utf-8",
    )
    run(["acme", "--vicelabels", str(LABELS), str(TEST_ASM)])

    write_monitor_commands(main_loop_address(), frame_count)

    # Autostart costs roughly 25M cycles; each PAL frame is about 20k.
    limit = max(60_000_000, 30_000_000 + frame_count * 30_000)
    vice = shutil.which("x64sc") or shutil.which("x64sc.exe") or "x64sc"
    run(
        [
            vice,
            "-autostart",
            str(TEST_PRG),
            "-moncommands",
            str(MONITOR),
            "-limitcycles",
            str(limit),
            "-warp",
        ]
    )

    captured = len(list(FRAMES.glob("f*.png")))
    if captured < frame_count:
        sys.exit(f"expected {frame_count} frames, captured {captured}")


def encode_gif(start: int, end: int, fps: int, output: Path) -> None:
    input_frames = end - start + 1
    output_frames = round(input_frames * fps / 50)
    if output_frames <= 0:
        sys.exit("the selected frame range is too short for the requested fps")

    output.parent.mkdir(parents=True, exist_ok=True)
    run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-framerate",
            "50",
            "-start_number",
            str(start),
            "-i",
            str(FRAMES / "f%03d.png"),
            "-frames:v",
            str(output_frames),
            "-vf",
            (
                f"fps={fps},split[s0][s1];"
                "[s0]palettegen=max_colors=16:stats_mode=full[p];"
                "[s1][p]paletteuse=dither=none"
            ),
            "-loop",
            "0",
            str(output),
        ]
    )


def cleanup() -> None:
    for path in (TEST_ASM, TEST_PRG, LABELS, MONITOR):
        path.unlink(missing_ok=True)
    shutil.rmtree(FRAMES, ignore_errors=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Capture screenshots/gameplay.gif from a headless VICE run.",
    )
    parser.add_argument(
        "--capture-frames",
        type=int,
        default=500,
        help="number of frames to capture (default: 500)",
    )
    parser.add_argument(
        "--start-frame",
        type=int,
        default=250,
        help="first captured frame to encode (default: 250)",
    )
    parser.add_argument(
        "--end-frame",
        type=int,
        default=449,
        help="last captured frame to encode (default: 449)",
    )
    parser.add_argument(
        "--fps",
        type=int,
        default=25,
        help="GIF frame rate, at most 50 (default: 25)",
    )
    parser.add_argument(
        "--jump-first",
        type=int,
        default=288,
        help="frame of the first auto-jump (default: 288)",
    )
    parser.add_argument(
        "--jump-interval",
        type=int,
        default=93,
        help="frames between auto-jumps (default: 93)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / "screenshots" / "gameplay.gif",
        help="output GIF (default: screenshots/gameplay.gif)",
    )
    parser.add_argument(
        "--keep",
        action="store_true",
        help="keep the patched source, PRG, monitor file and PNG frames",
    )
    args = parser.parse_args()

    if args.capture_frames <= 0:
        parser.error("--capture-frames must be positive")
    if not 0 <= args.start_frame <= args.end_frame < args.capture_frames:
        parser.error("need 0 <= --start-frame <= --end-frame < --capture-frames")
    if not 1 <= args.fps <= 50:
        parser.error("--fps must be between 1 and 50")
    for name in ("jump_first", "jump_interval"):
        if not 0 <= getattr(args, name) <= 0xFFFF:
            parser.error(f"--{name.replace('_', '-')} must fit in 16 bits")
    return args


if __name__ == "__main__":
    args = parse_args()
    try:
        capture_frames(args.capture_frames, args.jump_first, args.jump_interval)
        encode_gif(args.start_frame, args.end_frame, args.fps, args.output)
    finally:
        if not args.keep:
            cleanup()
    print(f"wrote {args.output}")
