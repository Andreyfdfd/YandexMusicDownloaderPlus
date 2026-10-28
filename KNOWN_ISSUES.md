# Known issues / TODO

## Implemented in `fix/unavailable-track-reporting`

- Recognize upstream messages such as `[1866/6737] Трек ... не доступен для скачивания`.
- Keep unavailable-track messages separate from general/fatal errors, so they do not automatically trigger a retry of the entire playlist on their own.
- Create `unavailable-*.csv` with playlist index, total, displayed track label, number of observed attempts, pass names, and raw message(s).
- Make the end-of-pass summary warn when unavailable tracks were reported instead of claiming there were no detected problems.
- Include unavailable-track count and CSV path in `errors-*.txt`.
- Add menu option 5 to analyse an existing download log without launching a downloader pass.

## Implemented in `fix/dpapi-token-module-fallback`

- Use the native Windows DPAPI API directly for saved-token load/save, bypassing `Microsoft.PowerShell.Security` module autoload.
- Preserve the previous `ConvertFrom-SecureString` DPAPI hex format so the existing `%APPDATA%\\YandexMusicDownloaderPlus\\token.dpapi` can be reused without entering the token again.
- Keep the token encrypted at rest; do not use plaintext token files as a workaround.
- Added menu option 6 to test saved-token decryption without displaying the secret or making a network request.
- Added menu option 7 to verify encrypt/write/read/decrypt round-trip through a temporary DPAPI file; the original saved-token file is not modified, and the temporary file is removed.
- Windows test passed: menu option 6 decrypted the existing `token.dpapi`.
- Windows one-track run passed: the saved token was reused and `Just Blue.m4a` was created with a nonzero size (6,980,159 bytes). The local test confirms the file exists; playback/duration should be checked by the user if validating audio integrity.
- Windows round-trip test passed: menu option 7 decrypted the saved token, encrypted it to a temporary DPAPI file, reloaded and decrypted it, and confirmed the values match. The original saved-token file was not modified; the temporary file was removed.

## Implemented in `feature/download-result-summary`

- Take a snapshot of audio files in the destination before and after each pass and report new, modified, and newly/modified zero-length audio files.
- Parse distinct audio output paths reported by the downloader and report any reported paths that are absent after the pass or have no observed file change.
- Append the same per-pass file summary to the download log.
- Export `file-outcomes-*.csv` with one row per reported audio path and every new/changed audio file found in the destination. Rows include observed status, whether the downloader mentioned the path, existence and size before/after, and last-write time.
- Do not claim that a nonzero file is complete or playable based on size alone.

## Implemented in `feature/retry-incomplete-download`

- Add menu option 8 to select one of the ten most recent `download-*.log` files and retry using the URL and destination folder recorded in that log.
- Prefer the last URL actually passed to the downloader and use the most recent logged quality as the default; allow the user to choose a different quality.
- Keep `--skip-existing` enabled on every retry. Ask before moving zero-length audio files to a sibling quarantine directory so the downloader has a chance to recreate them; never delete them automatically.
- Record the source log path in the new run log. Re-enter the saved DPAPI token through the normal token flow; the token is not copied from the old log.

## Implemented in `feature/failed-track-recovery`

- Add a Python helper to enumerate tracks for supported source URLs through the installed `yandex_music` / `ymd` packages and save a per-run source inventory without storing the token in files or logs.
- Compare the current inventory with the last snapshot for the exact same source URL and emit `library-status-*.csv` rows for removed-from-source tracks, unavailable tracks, and tracks whose reported path is missing or zero-length after a pass. Never delete local music files.
- Add menu option 9 to build a retry queue from the selected run log, retry each track by direct URL through the main downloader, and offer the `yt-dlp` browser-session fallback for remaining failures.
- Probe downloaded audio duration with Mutagen and compare it with source metadata. Put unverified/short alternate results in staging; quarantine a newly created primary result if its duration is invalid instead of silently replacing the target.

## Remaining work

### 1. Reliable upstream counters and audio validation

- Exact counts of all playlist entries processed and existing files silently skipped remain unavailable unless the upstream downloader exposes them.
- File snapshots measure changes in the destination folder during the pass. They do not verify audio duration, decodability, tags, or whether another process changed a file concurrently.
- Consider adding media-duration validation and a stronger success/failure signal if the upstream downloader exposes enough metadata.

### 2. Detecting nonzero partial files

The retry menu handles missing files by rerunning the entire source with `--skip-existing`. Zero-byte audio files can be moved to quarantine after confirmation. A nonzero partial or corrupted audio file may still be treated as existing and skipped; automatic duration/decodability validation remains future work. Do not auto-delete local files. Any alternate-backend output should stay in a staging folder until the user verifies duration and tags.

### 3. Progress and logging

Keep live progress in the original terminal and ensure the same track-level output is appended to the run log. Continue to test Unicode names and ensure the final report parses the log/output from the current run, including non-English messages.

### 4. Test matrix

- Existing file is skipped
- Missing normal track downloads
- Unavailable track is recorded as unavailable rather than general success
- Menu option 5 analyses the prior log without asking for a token or starting a download
- Repeated unavailable message from a retry becomes one CSV row with an attempts count
- Expired/invalid token produces a clear auth error
- Ctrl+C leaves files already completed intact
- Saved DPAPI token is reused by the same Windows user
