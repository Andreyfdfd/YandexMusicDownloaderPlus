# Third-party backend notice

The files in this directory include an adapted packaging of the Yandex Music API client from:

- Project: https://github.com/vladimir120307-droid/yandex-music-downloader
- Upstream files: `desktop/yandex_music.py`, `desktop/ffmpeg_helper.py`
- Upstream license: MIT; see `LICENSE-MIT.txt`
- Upstream project author: vladimir120307-droid

The CLI bridge in `yandex_music_cli.py` is written for Downloader Plus and passes the OAuth token through a temporary process environment variable. It does not write the token to command-line arguments, logs, or export files.

The backend uses the account-authenticated Yandex Music endpoints. It is not guaranteed to remain compatible with future service changes and does not override account entitlements or access-denied responses.
