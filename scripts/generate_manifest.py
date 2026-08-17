# -*- coding: utf-8 -*-
"""Generate a lightweight chapter-folder manifest for a Venera local comic."""

import json
import re
import sqlite3
from collections import Counter
from pathlib import Path

COMIC_ID = "caichunduileisifengsudayouxingqu"
COMIC_ROOT = Path(r"F:\venera\彩純對蕾絲風俗大有興趣！")
LOCAL_DB = Path(r"C:\Users\26981\AppData\Roaming\com.github.wgh136\venera\local.db")
OUTPUT_MD = Path(r"F:\venera\彩純對蕾絲風俗大有興趣！_章节信息.md")
OUTPUT_JSON = Path(r"F:\venera\彩純對蕾絲風俗大有興趣！_章节信息.json")

DEFAULT_GROUP = "默認"


def load_mapping(db_path: Path, comic_id: str) -> dict[str, tuple[str, str]]:
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


def natural_key(path: Path):
    m = re.match(r"(\d+)", path.stem)
    return (0, int(m.group(1)), path.name) if m else (1, path.name)


def main():
    title, mapping = load_mapping(LOCAL_DB, COMIC_ID)

    rows = []
    total_images = 0
    total_bytes = 0

    for folder in sorted(COMIC_ROOT.iterdir()):
        if not folder.is_dir():
            continue
        uuid = folder.name
        if uuid not in mapping:
            continue
        group, raw_name, display = mapping[uuid]
        images = [p for p in folder.iterdir() if p.is_file()]
        images.sort(key=natural_key)
        size = sum(p.stat().st_size for p in images)
        total_images += len(images)
        total_bytes += size
        rows.append({
            "folder": uuid,
            "group": group,
            "chapter": raw_name,
            "display_name": display,
            "image_count": len(images),
            "size_bytes": size,
            "size_mb": round(size / 1024 / 1024, 2),
        })

    rows.sort(key=lambda r: r["display_name"])

    manifest = {
        "comic_id": COMIC_ID,
        "title": title,
        "root": str(COMIC_ROOT),
        "total_chapters": len(rows),
        "total_images": total_images,
        "total_size_mb": round(total_bytes / 1024 / 1024, 2),
        "chapters": rows,
    }

    OUTPUT_JSON.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    lines = [
        f"# {title} 章节文件夹信息",
        "",
        f"- 根目录：`{COMIC_ROOT}`",
        f"- 章节数：{len(rows)}",
        f"- 图片总数：{total_images}",
        f"- 总大小：{round(total_bytes / 1024 / 1024, 2)} MB",
        "",
        "| 章节显示名 | 分组 | 原始章节名 | 文件夹 UUID | 图片数 | 大小(MB) |",
        "|---|---|---|---|---|---|",
    ]
    for r in rows:
        lines.append(
            f"| {r['display_name']} | {r['group']} | {r['chapter']} | "
            f"`{r['folder']}` | {r['image_count']} | {r['size_mb']} |"
        )
    OUTPUT_MD.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"Manifest written:")
    print(f"  MD  : {OUTPUT_MD}")
    print(f"  JSON: {OUTPUT_JSON}")


if __name__ == "__main__":
    main()
