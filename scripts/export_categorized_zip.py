# -*- coding: utf-8 -*-
"""
Create a categorized folder (group -> readable chapter name -> images)
from a Venera local comic, then package it into a ZIP.

The ZIP uses STORE (no recompression), so image quality is fully preserved.
"""

import json
import re
import shutil
import sqlite3
import zipfile
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

COMIC_ID = "caichunduileisifengsudayouxingqu"
COMIC_ROOT = Path(r"F:\venera\彩純對蕾絲風俗大有興趣！")
LOCAL_DB = Path(r"C:\Users\26981\AppData\Roaming\com.github.wgh136\venera\local.db")
OUTPUT_ROOT = Path(r"F:\venera\分享_彩純對蕾絲風俗大有興趣！_分类")
OUTPUT_ZIP = Path(r"F:\venera\分享_彩純對蕾絲風俗大有興趣！_分类.zip")

DEFAULT_GROUP = "默認"
COPY_WORKERS = 8


def natural_key(path: Path):
    m = re.match(r"(\d+)", path.stem)
    return (0, int(m.group(1)), path.name) if m else (1, path.name)


def load_mapping(db_path: Path, comic_id: str) -> tuple[str, dict[str, tuple[str, str]]]:
    con = sqlite3.connect(str(db_path))
    try:
        cur = con.cursor()
        cur.execute("SELECT title, chapters FROM comics WHERE id=?", (comic_id,))
        row = cur.fetchone()
        if row is None:
            raise RuntimeError("comic not found")
        title, chapters_json = row
        chapters = json.loads(chapters_json)
    finally:
        con.close()

    uuid_info: dict[str, tuple[str, str]] = {}
    for group, items in chapters.items():
        for uuid, name in items.items():
            uuid_info[uuid] = (group, name)

    name_counts = Counter(name for _, name in uuid_info.values())

    def display(group: str, name: str) -> str:
        if name_counts[name] > 1 or group != DEFAULT_GROUP:
            return f"{group}_{name}"
        return name

    return title, {u: (group, name, display(group, name)) for u, (group, name) in uuid_info.items()}


def copy_one(args):
    src, dst = args
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    return src.name


def main():
    if OUTPUT_ROOT.exists():
        shutil.rmtree(OUTPUT_ROOT)
    if OUTPUT_ZIP.exists():
        OUTPUT_ZIP.unlink()

    title, mapping = load_mapping(LOCAL_DB, COMIC_ID)
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)

    tasks = []
    chapter_count = 0
    for folder in COMIC_ROOT.iterdir():
        if not folder.is_dir() or folder.name not in mapping:
            continue
        group, raw_name, display = mapping[folder.name]
        images = [p for p in folder.iterdir() if p.is_file()]
        images.sort(key=natural_key)
        for img in images:
            dst = OUTPUT_ROOT / group / display / img.name
            tasks.append((img, dst))
        chapter_count += 1

    print(f"Copying {len(tasks)} images from {chapter_count} chapters with {COPY_WORKERS} workers...")
    with ThreadPoolExecutor(max_workers=COPY_WORKERS) as pool:
        futures = [pool.submit(copy_one, t) for t in tasks]
        done = 0
        for fut in as_completed(futures):
            fut.result()
            done += 1
            if done % 200 == 0:
                print(f"  copied {done}/{len(tasks)}")

    print("Creating ZIP (STORE, no recompression)...")
    with zipfile.ZipFile(OUTPUT_ZIP, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as zf:
        for path in sorted(OUTPUT_ROOT.rglob("*")):
            if path.is_file():
                zf.write(path, arcname=path.relative_to(OUTPUT_ROOT.parent))

    size_gb = OUTPUT_ZIP.stat().st_size / 1024 / 1024 / 1024
    print(f"Done.")
    print(f"Folder: {OUTPUT_ROOT}")
    print(f"ZIP   : {OUTPUT_ZIP} ({size_gb:.2f} GB)")


if __name__ == "__main__":
    main()
