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
- Menu option 5 analyses the prior log without asking for a token or starting a download
- Repeated unavailable message from a retry becomes one CSV row with an attempts count
- Expired/invalid token produces a clear auth error
- Ctrl+C leaves files already completed intact
- Saved DPAPI token is reused by the same Windows user
