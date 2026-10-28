# Changelog

## 0.1.1 — 2026-10-28

- Fixed classification of upstream `не доступен для скачивания` messages.
- Added a machine-readable `unavailable-*.csv` report with playlist position, track label, attempts, pass names, and raw messages.
- Updated end-of-pass output to warn when tracks are unavailable instead of reporting an unqualified success.
- Kept unavailable-track reports separate from general errors so unavailable-only runs do not automatically retry the entire playlist.
- Expanded `errors-*.txt` with summary counts and the CSV report path.

## 0.1.0 — 2026-10-28

- Initial repository snapshot of the locally tested Downloader Plus wrapper.
- Added persistent token storage through Windows DPAPI.
- Enabled unbuffered downloader output for live terminal progress and logging.
- Preserved skip-existing behavior and the existing music path pattern.
- Documented the initial diagnostics limitations.
