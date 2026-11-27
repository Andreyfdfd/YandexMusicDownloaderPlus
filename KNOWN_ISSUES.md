# Current status: implemented behavior and remaining limitations

This file describes the current code on the 0.3.0 release line. It replaces the older branch-by-branch TODO list, which contained several items that have since been implemented.

## Implemented and covered by automated checks

- **Windows desktop app:** WPF client on .NET Framework 4.8 with download, export, recovery, logs and settings sections. The console wrapper remains available as a secondary mode.
- **Shared orchestration:** GUI calls the same PowerShell layer as the console; source inventory, reports, retries and backend selection are not duplicated in the WPF client.
- **DPAPI token storage:** same per-user %APPDATA%\YandexMusicDownloaderPlus\token.dpapi format is shared between GUI and console. GUI self-test performs a protect/read/unprotect round-trip.
- **Primary launcher token handling:** bundled launcher receives the token through a temporary environment variable and injects it inside Python after process start, so it is absent from the bundled child process command line.
- **Metadata export:** CSV, JSON, TXT and XML serializers are tested offline. Tokens and audio files are excluded.
- **Independent API backend:** supports track, album, playlist and paginated artist sources.
- **Recovery safety:** alternate downloads are staged, checked for readability/duration, and moved into the library only after validation. Suspect zero-length or partial results are preserved in quarantine rather than deleted.
- **Unavailable track reports:** unavailable CSV, errors TXT, per-file outcome reports and library-status snapshots.
- **Windows installer:** bundled Python, main launcher, independent API module, optional yt-dlp plugin, WPF GUI and shortcuts. CI performs a silent install and validates required files and GUI self-test.

## Remaining limitations (not defects that can be solved entirely inside this wrapper)

### Service/API dependencies

- **Live authenticated integration is not exercised by GitHub CI.** CI cannot access the user's Yandex account/token. Before each stable release, manually verify one track, one album, a multi-track playlist and an artist page with a valid account.
- **Yandex Music API may change.** The independent client reduces coupling to the main CLI but can also require maintenance if endpoints, response schemas, stream signing or account access change.
- **A service-side access denial is terminal.** HTTP 401/403/429, not-allowed, DRM, region/subscription restrictions and unavailable tracks are not bypassed by switching backend.
- **Full access is account-dependent.** A logged-in browser or OAuth token does not imply the account is entitled to obtain every full-length stream in every format.
- **Playlist/artist metadata may be incomplete or paginated differently** after upstream API changes. A failed inventory does not stop download mode, but removal comparisons are skipped for that run.

### Audio integrity and file accounting

- **A matching duration is not a cryptographic integrity proof.** A file may still contain codec artifacts, missing tags or damaged audio frames despite a matching duration.
- **Silent upstream skips cannot be counted exactly** unless the main downloader reports them. Before/after filesystem snapshots and per-file CSVs provide observed results, not a server-confirmed success count.
- **Existing files with unknown expected duration are preserved.** The app does not auto-quarantine a nonzero file if it cannot compare its duration to reliable source metadata; manual review is safer than guessing.
- **Cancelled downloads may leave staging or partial files.** They are not automatically deleted; review logs and use recovery to assess them.

### Platform and GUI

- **Windows only.** The bundled installer targets x64 Windows 10 22H2 and Windows 11. The WPF GUI uses .NET Framework 4.8.
- **The browser fallback needs an open, authenticated browser profile.** The user explicitly authorizes this at run time; locked profiles or browser cookie encryption can prevent extraction.
- **The console route remains supported** for diagnosis or older scripts, but the WPF GUI is now the primary entry point.
- **The installer is not code-signed.** SmartScreen may show a publisher warning; verify the release checksum before running it.

## Manual release smoke-test checklist

1. Install on a clean Windows 10 22H2 or Windows 11 profile.
2. Save and reload a token in the GUI; also verify the console mode sees the same DPAPI token.
3. Download one single track to a temporary folder; listen to the result and inspect tags.
4. Download a short playlist and an album; verify skipped existing files and file layout.
5. Export the same playlist to CSV, JSON, TXT and XML; confirm track count and ordering.
6. Run a deliberately interrupted download and resume/recover it.
7. Test a valid artist URL and ensure the result count matches the web client's track list.
8. Test the browser fallback only after explicitly consenting and using a profile logged in to the intended account.
