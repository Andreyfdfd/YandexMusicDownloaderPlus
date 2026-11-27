#!/usr/bin/env python
"""Yandex Music source inventory and audio-duration probe for Downloader Plus.

The token is read only from YMDPLUS_INVENTORY_TOKEN and is never written to
stdout, the inventory JSON, or any log. This helper reuses the yandex-music
and ymd packages installed with the configured downloader.
"""
from __future__ import annotations

import argparse
import csv
import json
import logging
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET
from urllib.parse import urlparse

from yandex_music import Client
from ymd import core

PATH_PATTERN = Path("#album-artist", "#album", "#number - #title")
BATCH_SIZE = 10
AUDIO_SUFFIXES = {".m4a", ".mp3", ".flac", ".aac", ".ogg", ".opus", ".wav", ".wma", ".aiff", ".ape"}


def hydrate_tracks(client, track_refs, delay_seconds=0.0):
    # TrackShort.track_id includes album_id when needed to disambiguate versions.
    ids = [getattr(item, "track_id", None) or getattr(item, "id", None) for item in track_refs]
    ids = [str(value) for value in ids if value is not None]
    result = []
    for start in range(0, len(ids), BATCH_SIZE):
        batch = client.tracks(ids[start : start + BATCH_SIZE])
        result.extend(batch or [])
        if delay_seconds > 0 and start + BATCH_SIZE < len(ids):
            time.sleep(delay_seconds)
    return result


def tracks_for_source(client, source_url, delay_seconds=0.0):
    path = urlparse(source_url).path.rstrip("/")

    # Match the upstream CLI's URL interpretation order.
    track_match = re.search(r"/track/(\d+)$", path)
    if track_match:
        return client.tracks(track_match.group(1)) or []

    album_match = re.search(r"/album/(\d+)$", path)
    if album_match:
        album = client.albums_with_tracks(album_match.group(1))
        if not album or not album.volumes:
            return []
        tracks = []
        for volume in album.volumes:
            for track in volume:
                if track.albums:
                    track.albums[0].volumes = album.volumes
                tracks.append(track)
        return tracks

    artist_match = re.search(r"/artist/(\d+)$", path)
    if artist_match:
        artist_id = artist_match.group(1)
        page = 0
        album_ids = []
        while True:
            page_result = client.artists_direct_albums(artist_id, page=page, page_size=20)
            if delay_seconds > 0:
                time.sleep(delay_seconds)
            if not page_result or not page_result.albums:
                break
            album_ids.extend(str(album.id) for album in page_result.albums if album.id is not None)
            pager = getattr(page_result, "pager", None)
            if not pager or pager.per_page * (page + 1) >= pager.total:
                break
            page += 1
        tracks = []
        for album_id in album_ids:
            album = client.albums_with_tracks(album_id)
            if delay_seconds > 0:
                time.sleep(delay_seconds)
            if not album or not album.volumes:
                continue
            for volume in album.volumes:
                for track in volume:
                    if track.albums:
                        track.albums[0].volumes = album.volumes
                    tracks.append(track)
        return tracks

    playlist_match = re.search(r"/playlists/([^/]+)$", path)
    if playlist_match:
        playlist_id = playlist_match.group(1)
        if playlist_id.startswith("lk."):
            liked = client.users_likes_tracks()
            if delay_seconds > 0:
                time.sleep(delay_seconds)
            refs = getattr(liked, "tracks", None) or []
            return hydrate_tracks(client, refs, delay_seconds)

        playlist = client.playlist(playlist_id)
        if delay_seconds > 0:
            time.sleep(delay_seconds)
        if playlist is None:
            raise RuntimeError("API не вернул плейлист по указанной ссылке.")
        refs = playlist.fetch_tracks() or []
        if delay_seconds > 0:
            time.sleep(delay_seconds)
        return hydrate_tracks(client, refs, delay_seconds)

    raise RuntimeError(
        "Для ссылки не удалось определить источник. Поддерживаются ссылки на трек, альбом, "
        "исполнителя или плейлист, которые принимает основной загрузчик."
    )


def track_record(track, index):
    track_id = getattr(track, "id", None)
    if track_id is None:
        raise RuntimeError(f"У записи источника с позицией {index} отсутствует ID трека.")

    artists = ", ".join(
        str(artist.name) for artist in (getattr(track, "artists", None) or [])
        if getattr(artist, "name", None)
    )
    albums = getattr(track, "albums", None) or []
    album = albums[0] if albums else None
    title = core.full_title(track)
    album_title = core.full_title(album) if album else ""
    album_id = getattr(album, "id", None) if album else None
    duration_ms = getattr(track, "duration_ms", None) or 0
    relative_base = core.prepare_base_path(PATH_PATTERN, track)
    raw_title = str(getattr(track, "title", None) or title)
    album_artist = ", ".join(
        str(artist.name) for artist in (getattr(album, "artists", None) or [])
        if getattr(artist, "name", None)
    ) if album else ""
    position = getattr(album, "track_position", None) if album else None
    if position is None:
        position = getattr(track, "track_position", None)
    track_number = getattr(position, "index", None) or ""
    disc_number = getattr(position, "volume", None) or ""
    year = getattr(album, "year", None) if album else None
    isrc = getattr(track, "isrc", None) or ""
    available = getattr(track, "available", None)
    if album_id is not None:
        track_url = f"https://music.yandex.ru/album/{album_id}/track/{track_id}"
    else:
        track_url = f"https://music.yandex.ru/track/{track_id}"

    return {
        "SourceIndex": index,
        "TrackId": str(track_id),
        "TrackKey": f"{track_id}:{album_id}" if album_id is not None else str(track_id),
        "TrackTitle": title,
        "Title": raw_title,
        "Version": str(getattr(track, "version", None) or ""),
        "TrackLabel": f"{artists} - {raw_title}".strip(" -"),
        "Artists": artists,
        "AlbumTitle": album_title,
        "AlbumArtist": album_artist,
        "AlbumId": "" if album_id is None else str(album_id),
        "Year": "" if year is None else str(year),
        "ISRC": str(isrc),
        "TrackNumber": "" if track_number is None else str(track_number),
        "DiscNumber": "" if disc_number is None else str(disc_number),
        "Available": "" if available is None else str(bool(available)).lower(),
        "TrackUrl": track_url,
        "RelativeBasePath": str(relative_base).replace("\\", "/"),
        "DurationMs": int(duration_ms),
        "DurationSeconds": round(int(duration_ms) / 1000.0, 3) if duration_ms else "",
    }


def collect_inventory(source_url, delay_seconds=0.0):
    token = os.environ.get("YMDPLUS_INVENTORY_TOKEN")
    if not token:
        raise RuntimeError("Не получен токен через временную переменную окружения.")
    client = Client(token)
    client.init()
    if delay_seconds > 0:
        time.sleep(delay_seconds)
    tracks = tracks_for_source(client, source_url, delay_seconds)
    return [track_record(track, index) for index, track in enumerate(tracks, start=1)]


def run_inventory(args):
    records = collect_inventory(args.url, args.delay)
    output = {
        "success": True,
        "sourceUrl": args.url,
        "count": len(records),
        "tracks": records,
    }
    Path(args.output_json).write_text(
        json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def write_export_files(source_url, output_dir, prefix, records):
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    prefix = prefix.strip() or "yandex-music-backup"
    csv_path = output_dir / f"{prefix}.csv"
    json_path = output_dir / f"{prefix}.json"
    txt_path = output_dir / f"{prefix}.txt"
    xml_path = output_dir / f"{prefix}.xml"

    # Soundiiz-compatible columns. Extra source_* columns preserve provenance,
    # while title/artist/album/isrc/duration are the fields used for matching.
    csv_columns = [
        "title", "artist", "album", "isrc", "platform", "trackId", "duration",
        "url", "source_index", "source_url", "album_id", "year",
        "track_number", "disc_number", "album_artist",
    ]
    with csv_path.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=csv_columns, extrasaction="ignore")
        writer.writeheader()
        for row in records:
            writer.writerow({
                "title": row.get("Title") or row.get("TrackTitle") or "",
                "artist": row.get("Artists") or "",
                "album": row.get("AlbumTitle") or "",
                "isrc": row.get("ISRC") or "",
                "platform": "Yandex Music",
                "trackId": row.get("TrackId") or "",
                "duration": row.get("DurationSeconds") or "",
                # Soundiiz's URL field is documented for Spotify URLs; keep the
                # Yandex source URL in a custom column so it is not misresolved.
                "url": "",
                "source_index": row.get("SourceIndex") or "",
                "source_url": row.get("TrackUrl") or "",
                "album_id": row.get("AlbumId") or "",
                "year": row.get("Year") or "",
                "track_number": row.get("TrackNumber") or "",
                "disc_number": row.get("DiscNumber") or "",
                "album_artist": row.get("AlbumArtist") or "",
            })

    exported_at = datetime.now(timezone.utc).isoformat()
    backup = {
        "format": "YandexMusicDownloaderPlusLibraryBackup",
        "formatVersion": 1,
        "platform": "Yandex Music",
        "sourceUrl": source_url,
        "exportedAtUtc": exported_at,
        "trackCount": len(records),
        "tracks": records,
    }
    json_path.write_text(json.dumps(backup, ensure_ascii=False, indent=2), encoding="utf-8")

    text_lines = [
        f"{row.get('Artists') or 'Unknown Artist'} - {row.get('Title') or row.get('TrackTitle') or 'Unknown Title'}"
        for row in records
    ]
    txt_path.write_text("\\n".join(text_lines) + ("\\n" if text_lines else ""), encoding="utf-8-sig")

    root = ET.Element("playlist", {"title": prefix})
    for row in records:
        node = ET.SubElement(root, "track")
        ET.SubElement(node, "title").text = row.get("Title") or row.get("TrackTitle") or ""
        ET.SubElement(node, "artist").text = row.get("Artists") or ""
        ET.SubElement(node, "album").text = row.get("AlbumTitle") or ""
        if row.get("ISRC"):
            ET.SubElement(node, "isrc").text = row["ISRC"]
        # Additional fields are preserved for tools that ignore unknown tags.
        ET.SubElement(node, "source_url").text = row.get("TrackUrl") or ""
        ET.SubElement(node, "track_id").text = row.get("TrackId") or ""
    ET.indent(root, space="  ")
    ET.ElementTree(root).write(xml_path, encoding="utf-8", xml_declaration=True)

    return {
        "success": True,
        "count": len(records),
        "files": {
            "csv": str(csv_path),
            "json": str(json_path),
            "txt": str(txt_path),
            "xml": str(xml_path),
        },
    }


def run_export(args):
    records = collect_inventory(args.url, args.delay)
    manifest = write_export_files(args.url, args.output_dir, args.prefix, records)
    print(json.dumps(manifest, ensure_ascii=False))

def run_duration(args):
    from mutagen import File as MutagenFile

    path = Path(args.path)
    audio = MutagenFile(path)
    if audio is None or getattr(audio, "info", None) is None:
        raise RuntimeError("Mutagen не распознал аудиофайл или его длительность.")
    seconds = float(audio.info.length)
    if seconds <= 0:
        raise RuntimeError("Длительность файла равна нулю.")
    result = {"success": True, "durationSeconds": seconds}
    print(json.dumps(result, ensure_ascii=False))


def main():
    logging.basicConfig(level=logging.CRITICAL)
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    inventory = sub.add_parser("inventory")
    inventory.add_argument("--url", required=True)
    inventory.add_argument("--output-json", required=True)
    inventory.add_argument("--delay", type=float, default=0.0)
    inventory.set_defaults(handler=run_inventory)
    export = sub.add_parser("export")
    export.add_argument("--url", required=True)
    export.add_argument("--output-dir", required=True)
    export.add_argument("--prefix", required=True)
    export.add_argument("--delay", type=float, default=0.0)
    export.set_defaults(handler=run_export)
    duration = sub.add_parser("duration")
    duration.add_argument("--path", required=True)
    duration.set_defaults(handler=run_duration)
    args = parser.parse_args()
    try:
        args.handler(args)
        return 0
    except Exception as exc:
        if args.command == "inventory":
            try:
                Path(args.output_json).write_text(
                    json.dumps({"success": False, "error": f"{type(exc).__name__}: {exc}"}, ensure_ascii=False, indent=2),
                    encoding="utf-8",
                )
            except Exception:
                pass
        elif args.command == "export":
            print(json.dumps({"success": False, "error": f"{type(exc).__name__}: {exc}"}, ensure_ascii=False))
        else:
            print(json.dumps({"success": False, "error": f"{type(exc).__name__}: {exc}"}, ensure_ascii=False))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
