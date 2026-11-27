#!/usr/bin/env python
"""One-track CLI bridge for the optional, separately implemented Yandex Music API backend.

The OAuth token is read from YMDPLUS_BACKEND_TOKEN, never from command-line
arguments and never written to logs. This adapter does not bypass account,
subscription, region, or track-availability restrictions.
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
import sys
import traceback
from pathlib import Path

import yandex_music


def main() -> int:
    parser = argparse.ArgumentParser(description="One-track Yandex Music fallback backend")
    parser.add_argument("--url", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--quality", choices=("auto", "flac", "mp3-320"), default="auto")
    parser.add_argument("--lyrics", action="store_true")
    parser.add_argument("--cancel-file", default="")
    args = parser.parse_args()

    token = os.environ.get("YMDPLUS_BACKEND_TOKEN")
    if not token:
        print(json.dumps({"success": False, "error": "YMDPLUS_BACKEND_TOKEN is not set"}, ensure_ascii=False))
        return 2

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    def cancel_check() -> bool:
        return bool(args.cancel_file) and Path(args.cancel_file).exists()

    def progress_cb(progress: dict) -> None:
        message = progress.get("message")
        if message:
            print(f"[Direct API] {message}", file=sys.stderr, flush=True)

    try:
        # Keep upstream progress/debug prints off stdout so the final line is a
        # single machine-readable JSON result for the PowerShell router.
        with contextlib.redirect_stdout(sys.stderr):
            output_path = yandex_music.download(
                args.url,
                str(output_dir),
                token=token,
                progress_cb=progress_cb,
                cancel_check=cancel_check,
                quality=args.quality,
                want_lyrics=args.lyrics,
            )
        path = Path(output_path).resolve()
        root = output_dir.resolve()
        try:
            path.relative_to(root)
        except ValueError:
            raise RuntimeError("Backend produced a path outside the assigned staging directory.")
        if cancel_check():
            raise RuntimeError("Операция отменена пользователем.")
        if not path.is_file() or path.stat().st_size <= 0:
            raise RuntimeError("Backend did not produce a non-empty audio file.")
        print(json.dumps({"success": True, "path": str(path), "size": path.stat().st_size}, ensure_ascii=False))
        return 0
    except Exception as exc:
        print(
            json.dumps(
                {
                    "success": False,
                    "error": f"{type(exc).__name__}: {exc}",
                    "traceback": traceback.format_exc(limit=8),
                },
                ensure_ascii=False,
            )
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
