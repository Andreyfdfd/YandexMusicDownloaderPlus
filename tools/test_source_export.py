#!/usr/bin/env python
from __future__ import annotations

import csv
import json
import sys
import tempfile
from pathlib import Path
from xml.etree import ElementTree as ET

TOOLS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS_DIR))
from source_inventory import direct_api_track_record, write_export_files  # noqa: E402


def main() -> int:
    records = [
        {
            "SourceIndex": 1, "TrackId": "123", "TrackKey": "123:456",
            "TrackTitle": "Космическая музыка — Remaster", "Title": "Космическая музыка",
            "Version": "Remaster", "TrackLabel": "Группа, Исполнитель - Космическая музыка",
            "Artists": "Группа, Исполнитель", "AlbumTitle": "Альбом, Vol. 1",
            "AlbumArtist": "Группа", "AlbumId": "456", "Year": "2024",
            "ISRC": "RUA1A2400001", "TrackNumber": "7", "DiscNumber": "1",
            "Available": "true", "TrackUrl": "https://music.yandex.ru/album/456/track/123",
            "RelativeBasePath": "Группа/Альбом, Vol. 1/07 - Космическая музыка",
            "DurationMs": 215321, "DurationSeconds": 215.321,
        },
        {
            "SourceIndex": 2, "TrackId": "789", "TrackKey": "789:456",
            "TrackTitle": "Night Drive", "Title": "Night Drive", "Version": "",
            "TrackLabel": "Artist - Night Drive", "Artists": "Artist",
            "AlbumTitle": "Album", "AlbumArtist": "Artist", "AlbumId": "456",
            "Year": "2025", "ISRC": "", "TrackNumber": "8", "DiscNumber": "1",
            "Available": "true", "TrackUrl": "https://music.yandex.ru/album/456/track/789",
            "RelativeBasePath": "Artist/Album/08 - Night Drive",
            "DurationMs": 190000, "DurationSeconds": 190.0,
        },
    ]

    direct_record = direct_api_track_record(
        {
            "trackId": "900",
            "albumId": "901",
            "title": "Ночной маршрут",
            "artist": "Исполнитель",
            "album": "Сборник",
            "albumArtist": "Исполнитель",
            "trackNum": 3,
            "discNum": 1,
            "year": 2026,
            "isrc": "RUA1A2600009",
            "durationMs": 201500,
        },
        1,
    )
    assert direct_record["TrackId"] == "900"
    assert direct_record["TrackUrl"].endswith("/album/901/track/900")
    assert direct_record["ISRC"] == "RUA1A2600009"
    assert direct_record["RelativeBasePath"] == "Исполнитель/Сборник/03 - Ночной маршрут"
    assert "\\" not in direct_record["RelativeBasePath"]

    with tempfile.TemporaryDirectory(prefix="ymdp-export-test-") as temp_dir:
        manifest = write_export_files(
            "https://music.yandex.ru/playlists/lk.test",
            temp_dir,
            "test-backup",
            records,
        )
        assert manifest["success"] is True
        assert manifest["count"] == 2

        csv_path = Path(manifest["files"]["csv"])
        with csv_path.open("r", encoding="utf-8-sig", newline="") as stream:
            csv_rows = list(csv.DictReader(stream))
        assert len(csv_rows) == 2
        assert csv_rows[0]["title"] == "Космическая музыка"
        assert csv_rows[0]["artist"] == "Группа, Исполнитель"
        assert csv_rows[0]["isrc"] == "RUA1A2400001"
        assert csv_rows[0]["trackId"] == "123"
        assert csv_rows[0]["duration"] == "215.321"
        assert csv_rows[0]["source_url"].endswith("/track/123")

        backup = json.loads(Path(manifest["files"]["json"]).read_text(encoding="utf-8"))
        assert backup["trackCount"] == 2
        assert backup["tracks"][1]["TrackId"] == "789"
        assert backup["sourceUrl"].endswith("lk.test")

        plain_lines = Path(manifest["files"]["txt"]).read_text(encoding="utf-8-sig").splitlines()
        assert plain_lines == [
            "Группа, Исполнитель - Космическая музыка",
            "Artist - Night Drive",
        ]

        xml_root = ET.parse(manifest["files"]["xml"]).getroot()
        xml_tracks = xml_root.findall("track")
        assert len(xml_tracks) == 2
        assert xml_tracks[0].findtext("title") == "Космическая музыка"
        assert xml_tracks[0].findtext("artist") == "Группа, Исполнитель"
        assert xml_tracks[0].findtext("isrc") == "RUA1A2400001"

    print("Metadata export serialization tests: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
