# -*- coding: utf-8 -*-
"""
Export Venera local comic chapter folders to separate lossless PDFs.

Reads chapter UUID -> display name mapping from Venera local.db,
then uses img2pdf to embed the original image files into PDFs without
re-encoding/recompressing them.
"""

import json
import re
import sqlite3
from collections import Counter
from pathlib import Path

import img2pdf

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
COMIC_ID = "caichunduileisifengsudayouxingqu"
COMIC_ROOT = Path(r"F:\venera\彩純對蕾絲風俗大有興趣！")
LOCAL_DB = Path(r"C:\Users\26981\AppData\Roaming\com.github.wgh136\venera\local.db")
OUTPUT_DIR = Path(r"F:\venera\分享_彩純對蕾絲風俗大有興趣！_PDF")

DEFAULT_GROUP = "默認"


def natural_sort_key(path: Path) -> tuple:
    """Sort filenames like 0.webp, 1.webp, ..., 10.webp numerically."""
    match = re.match(r"(\d+)", path.stem)
    if match:
        return (0, int(match.group(1)), path.name)
    return (1, path.name)


def load_chapter_mapping(db_path: Path, comic_id: str) -> dict[str, str]:
    """Return {uuid: display_name} using Venera's comics table."""
    con = sqlite3.connect(str(db_path))
    try:
        cur = con.cursor()
        cur.execute("SELECT chapters FROM comics WHERE id=?", (comic_id,))
        row = cur.fetchone()
        if row is None:
            raise RuntimeError(f"Comic id not found in local.db: {comic_id}")
        chapters = json.loads(row[0])
    finally:
        con.close()

    uuid_info: dict[str, tuple[str, str]] = {}
    for group, items in chapters.items():
        for uuid, name in items.items():
            uuid_info[uuid] = (group, name)

    name_counts = Counter(name for _, name in uuid_info.values())

    def display_name(group: str, name: str) -> str:
        if name_counts[name] > 1 or group != DEFAULT_GROUP:
            return f"{group}_{name}"
        return name

    return {uuid: display_name(group, name) for uuid, (group, name) in uuid_info.items()}


def main() -> None:
    if not COMIC_ROOT.is_dir():
        raise SystemExit(f"Comic folder not found: {COMIC_ROOT}")
    if not LOCAL_DB.is_file():
        raise SystemExit(f"local.db not found: {LOCAL_DB}")

    mapping = load_chapter_mapping(LOCAL_DB, COMIC_ID)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    chapter_dirs = sorted([p for p in COMIC_ROOT.iterdir() if p.is_dir()])
    if not chapter_dirs:
        raise SystemExit("No chapter folders found.")

    print(f"Found {len(chapter_dirs)} chapter folders.")
    ok_count = 0
    skip_count = 0

    for folder in chapter_dirs:
        uuid = folder.name
        if uuid not in mapping:
            print(f"SKIP (no mapping): {uuid}")
            skip_count += 1
            continue

        images = sorted(
            [p for p in folder.iterdir() if p.is_file()],
            key=natural_sort_key,
        )
        if not images:
            print(f"SKIP (no images): {uuid}")
            skip_count += 1
            continue

        display = mapping[uuid]
        # Sanitize for Windows filenames
        safe = re.sub(r'[<>:"/\\|?*]', "_", display).strip()
        pdf_path = OUTPUT_DIR / f"彩純對蕾絲風俗大有興趣！_{safe}.pdf"

        # img2pdf embeds the original image data losslessly (no re-encode).
        pdf_bytes = img2pdf.convert([str(p) for p in images])
        pdf_path.write_bytes(pdf_bytes)

        print(f"OK  {pdf_path.name}  ({len(images)} images, {pdf_path.stat().st_size / 1024 / 1024:.1f} MB)")
        ok_count += 1

    print(f"\nDone. Created {ok_count} PDFs, skipped {skip_count}.")
    print(f"Output: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
