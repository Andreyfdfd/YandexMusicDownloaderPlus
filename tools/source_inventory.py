#!/usr/bin/env python
"""Yandex Music source inventory and audio-duration probe for Downloader Plus.

The token is read only from YMDPLUS_INVENTORY_TOKEN and is never written to
stdout, the inventory JSON, or any log. This helper reuses the yandex-music
and ymd packages installed with the configured downloader.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
import time
from pathlib import Path
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
    if album_id is not None:
        track_url = f"https://music.yandex.ru/album/{album_id}/track/{track_id}"
    else:
        track_url = f"https://music.yandex.ru/track/{track_id}"

    return {
        "SourceIndex": index,
        "TrackId": str(track_id),
        "TrackKey": f"{track_id}:{album_id}" if album_id is not None else str(track_id),
        "TrackTitle": title,
        "TrackLabel": f"{artists} - {getattr(track, 'title', title)}".strip(" -"),
        "Artists": artists,
        "AlbumTitle": album_title,
        "AlbumId": "" if album_id is None else str(album_id),
        "TrackUrl": track_url,
        "RelativeBasePath": str(relative_base).replace("\\", "/"),
        "DurationMs": int(duration_ms),
    }


def run_inventory(args):
    token = os.environ.get("YMDPLUS_INVENTORY_TOKEN")
    if not token:
        raise RuntimeError("Не получен токен через временную переменную окружения.")
    client = Client(token)
    client.init()
    if args.delay > 0:
        time.sleep(args.delay)
    tracks = tracks_for_source(client, args.url, args.delay)
    records = [track_record(track, index) for index, track in enumerate(tracks, start=1)]

    output = {
        "success": True,
        "sourceUrl": args.url,
        "count": len(records),
        "tracks": records,
    }
    Path(args.output_json).write_text(
        json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8"
    )


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
                    json.dumps({"success": False, "error": str(exc)}, ensure_ascii=False, indent=2),
                    encoding="utf-8",
                )
            except Exception:
                pass
        else:
            print(json.dumps({"success": False, "error": str(exc)}, ensure_ascii=False))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
