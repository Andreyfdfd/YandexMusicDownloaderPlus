# Known issues / TODO

## 1. Classify unavailable tracks correctly

Observed in a real run on 2026-10-28: lines like

`[1866/6737] Трек Didier Marouani, Space - Just Blue не доступен для скачивания`

are printed during processing, while the final summary said there were no detected errors. The PowerShell error classifier needs to recognize `не доступен для скачивания` (with spaces), count these separately from fatal errors, and create a machine-readable CSV report with track index, total count, displayed artist/title, and raw message. It must not claim the pass succeeded when such lines exist.

## 2. Summary statistics

At the end of a pass, report at least:

- total entries processed (if the backend output exposes it)
- skipped/existing files, when identifiable
- newly downloaded tracks, when identifiable
- unavailable/failed tracks
- other errors

Do not guess counts that the backend does not expose.

## 3. Resume and duplicate safety

Preserve `--skip-existing` and the existing directory/path pattern. Do not auto-delete local files. Any alternate-backend output should stay in a staging folder until the user verifies duration and tags.

## 4. Progress and logging

Keep live progress in the original terminal and ensure the same track-level output is appended to the run log. Test Unicode names. Ensure the final report parses the log/output from the current run, including non-English messages.

## 5. Test matrix

- Existing file is skipped
- Missing normal track downloads
- Unavailable track is recorded as unavailable rather than general success
- Expired/invalid token produces a clear auth error
- Ctrl+C leaves files already completed intact
- Saved DPAPI token is reused by the same Windows user
