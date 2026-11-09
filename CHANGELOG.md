# Changelog

## 0.2.0-preview.2 — 2026-11-09

- Fix the Inno Setup default Music path using the current Windows user's USERPROFILE environment variable.
- Invoke the upstream downloader's registered `ymd.cli:main` entry point from the embedded launcher and force UTF-8 mode.
- Add a Windows smoke test that silently installs the setup, checks required files, runs the bundled CLI help, and confirms the Music path setting is saved.
- Use a separate preview.2 release rather than reusing the first test binary.


## 0.2.0-preview.1 — 2026-11-09

- Added a separate Windows installer built on Windows CI with a bundled portable CPython 3.14 runtime and the primary Yandex Music downloader.
- Added a native launcher that invokes the embedded Python module without depending on a system Python installation or hard-coded interpreter paths.
- Added selectable full/compact/custom installation types, optional yt-dlp preinstallation, optional documentation, desktop shortcut, and a selectable Music directory.
- Defaulted the music destination to the current Windows user's Music folder and moved its configuration to the user's AppData profile.
- Removed the personal liked-playlist URL from the release defaults; the source URL is now requested explicitly.
- Added a separate GitHub pre-release workflow and SHA-256 checksum for the installer.


## 0.1.6 — 2026-10-28

- Added source inventory snapshots and `library-status-*.csv` reports to list tracks removed from the same source since the previous snapshot and tracks known to have failed during a run.
- Added menu option 9 to build a queue of failed tracks from a previous log, retry each track individually through the main downloader, and optionally try `yt-dlp` as a fallback.
- Added duration checks using the downloader's installed Mutagen dependency; short or unverified fallback files are kept in staging instead of being silently added to the library.
- Added a Python helper that reads the DPAPI-decoded token from a temporary process environment variable and never writes it to the inventory file or logs.
- Applied the selected request delay to source-inventory batches and made a subsequent option-9 run continue only unresolved candidates from its previous recovery queue.

## 0.1.5 — 2026-10-28

- Added menu option 8 to select a previous `download-*.log` and retry the recorded URL/output folder, defaulting to the last observed quality.
- Preserved `--skip-existing` for retry runs and added an explicit, optional quarantine move for zero-length audio files; no files are automatically deleted.
- Logged the source run used for each retry.

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
