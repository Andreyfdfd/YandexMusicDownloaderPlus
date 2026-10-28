# Known issues / TODO

## Implemented in `fix/unavailable-track-reporting`

- Recognize upstream messages such as `[1866/6737] Трек ... не доступен для скачивания`.
- Keep unavailable-track messages separate from general/fatal errors, so they do not automatically trigger a retry of the entire playlist on their own.
- Create `unavailable-*.csv` with playlist index, total, displayed track label, number of observed attempts, pass names, and raw message(s).
- Make the end-of-pass summary warn when unavailable tracks were reported instead of claiming there were no detected problems.
- Include unavailable-track count and CSV path in `errors-*.txt`.

## Remaining work

### 1. Summary statistics

At the end of a pass, report at least:

- total entries processed (if the backend output exposes it)
- skipped/existing files, when identifiable
- newly downloaded tracks, when identifiable
- unavailable/failed tracks
- other errors

Do not guess counts that the backend does not expose. In particular, `[index/total]` is a position in the source list, not a downloaded-file count.

### 2. Resume and duplicate safety

Preserve `--skip-existing` and the existing directory/path pattern. Do not auto-delete local files. Any alternate-backend output should stay in a staging folder until the user verifies duration and tags.

### 3. Progress and logging

Keep live progress in the original terminal and ensure the same track-level output is appended to the run log. Continue to test Unicode names and ensure the final report parses the log/output from the current run, including non-English messages.

### 4. Test matrix

- Existing file is skipped
- Missing normal track downloads
- Unavailable track is recorded as unavailable rather than general success
- Repeated unavailable message from a retry becomes one CSV row with an attempts count
- Expired/invalid token produces a clear auth error
- Ctrl+C leaves files already completed intact
- Saved DPAPI token is reused by the same Windows user
