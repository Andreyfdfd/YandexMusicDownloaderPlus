# Changelog

## 0.1.4 — 2026-10-28

- Added a per-pass `file-outcomes-*.csv` report listing observed status for every path reported by the downloader and every new/changed audio file found in the output folder.
- Added before/after existence and size, downloader-reported flag, and last-write time to each file outcome row.

## 0.1.3 — 2026-10-28

- Added before/after snapshots of audio files for each download pass, reporting created, modified, and zero-length files.
- Parsed distinct audio paths reported by the downloader and flagged paths that are missing or unchanged after the pass.
- Appended filesystem result summaries to the log while explicitly avoiding guesses about silently skipped existing files.

## 0.1.2 — 2026-10-28

- Replaced `ConvertTo-SecureString` / `ConvertFrom-SecureString` calls for token storage with a small wrapper around the native Windows DPAPI API.
- Kept the existing DPAPI hex payload format for backward compatibility with the saved token file.
- Avoided storing the token as plaintext to work around a PowerShell Security module loading failure.
- Added menu option 6 to verify saved-token decryption offline without displaying the secret or starting a download.
- Added menu option 7 to test token decrypt/encrypt/file/reload round-trip in a temporary file without changing the saved token or contacting the network.

## 0.1.1 — 2026-10-28

- Fixed classification of upstream `не доступен для скачивания` messages.
- Added a machine-readable `unavailable-*.csv` report with playlist position, track label, attempts, pass names, and raw messages.
- Updated end-of-pass output to warn when tracks are unavailable instead of reporting an unqualified success.
- Kept unavailable-track reports separate from general errors so unavailable-only runs do not automatically retry the entire playlist.
- Expanded `errors-*.txt` with summary counts and the CSV report path.
- Added menu option 5 to rebuild diagnostics from an existing log without downloading music or requesting a token.

## 0.1.0 — 2026-10-28

- Initial repository snapshot of the locally tested Downloader Plus wrapper.
- Added persistent token storage through Windows DPAPI.
- Enabled unbuffered downloader output for live terminal progress and logging.
- Preserved skip-existing behavior and the existing music path pattern.
- Documented the initial diagnostics limitations.
