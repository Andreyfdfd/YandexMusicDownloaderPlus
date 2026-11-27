# Changelog

## 0.3.0 — 2026-11-27

- Added a Russian-language WPF desktop application for Windows with download, metadata export, recovery, logs and settings pages.
- Added live backend output, parsed track progress, cancellation marker support and process-tree cleanup from the GUI.
- Kept the PowerShell console workflow as a secondary launch option; both interfaces share the same engine, logs, settings and DPAPI token store.
- Added GUI headless mode so the desktop client invokes the existing PowerShell orchestration without interactive prompts.
- Added DPAPI token management to the GUI using the same per-user file as the PowerShell client.
- Changed the bundled Go launcher integration so the primary downloader token is injected into Python after process start rather than being included in the child process command line.
- Added paginated artist-track retrieval to the independent API backend.
- Added automatic duration/readability checks for existing nonzero recovery files; suspect files are moved to quarantine, never deleted, before recovery.
- Added installer packaging, desktop/start-menu shortcuts and Windows CI smoke tests for the WPF application and its DPAPI round-trip.
- Updated known-issues documentation to distinguish implemented protections from limits that still require live account testing.

## 0.2.0-preview.3 — 2026-11-27

- Added metadata-only library export (CSV, full JSON, TXT, XML) with title, artists, album, duration, ISRC, source position and track URL/IDs.
- Added an independent MIT-licensed Yandex Music API client as a second backend and as a fallback for source inventory/export when the primary client has incompatible URL/model handling.
- Added per-track failover flow: primary downloader → independent API backend → optional browser-session yt-dlp backend after explicit consent.
- Kept account/access denials, rate limiting, unavailable tracks, subscription/region requirements and DRM as terminal conditions; failover is not used to bypass them.
- Added offline export serialization tests, service-denial classifier tests, PowerShell parser validation and Windows installer smoke checks for the new backend.

## 0.2.0-preview.2 — 2026-11-09

- Fixed Inno Setup default Music path using the current Windows user's USERPROFILE.
- Invoked the upstream downloader's registered ymd.cli:main entry point from the embedded launcher and forced UTF-8 mode.
- Added a Windows smoke test that silently installs the setup, checks required files, runs the bundled CLI help, and confirms the Music path setting is saved.

## 0.2.0-preview.1 — 2026-11-09

- Added a separate Windows installer with a bundled portable CPython 3.14 runtime and primary downloader.
- Added a native launcher independent of system Python.
- Added full/compact/custom install types, optional yt-dlp, docs, desktop shortcut and selectable Music directory.
- Removed the personal liked-playlist URL from release defaults.

## 0.1.6 — 2026-10-28

- Added source inventory snapshots and library-status CSV.
- Added sequential recovery of failed tracks with optional yt-dlp fallback.
- Added duration checks and staging for unverified files.

## 0.1.5 — 2026-10-28

- Added retry of a prior download using URL and destination from its log.
- Preserved skip-existing; added quarantine for zero-length files.

## 0.1.4 — 2026-10-28

- Added per-pass file-outcomes CSV.

## 0.1.3 — 2026-10-28

- Added before/after audio snapshots and summaries.

## 0.1.2 — 2026-10-28

- Added native Windows DPAPI storage compatible with the existing token file.
- Added offline saved-token decryption and round-trip checks.

## 0.1.1 — 2026-10-28

- Added unavailable CSV and menu option 5 for offline log analysis.

## 0.1.0 — 2026-10-28

- Initial repository snapshot of the Downloader Plus wrapper.
