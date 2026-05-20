#!/usr/bin/env python3
import argparse
import hashlib
import random
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path


IGNORED_NAMES = {"gamelist.xml", "readme.md", ".gitkeep"}


def is_rom(path: Path, system_dir: Path) -> bool:
    if not path.is_file() or path.name.lower() in IGNORED_NAMES or path.name.startswith("."):
        return False
    rel = path.relative_to(system_dir)
    if any(part.startswith(".") or part.lower() in {"images", "videos", "manuals", "media"} for part in rel.parts):
        return False
    return True


def parse_source_metadata(system_dir: Path) -> dict:
    gamelist = system_dir / "gamelist.xml"
    if not gamelist.exists():
        return {}
    try:
        root = ET.parse(gamelist).getroot()
    except Exception:
        return {}
    metadata = {}
    for game in root.findall("game"):
        path_node = game.find("path")
        if path_node is None or not path_node.text:
            continue
        key = path_node.text.replace("\\", "/").lstrip("./")
        metadata[key] = game
    return metadata


def write_gamelist(system_dir: Path, roms: list[Path], source_metadata: dict) -> None:
    root = ET.Element("gameList")
    for rom in sorted(roms, key=lambda p: p.relative_to(system_dir).as_posix().lower()):
        rel = rom.relative_to(system_dir).as_posix()
        source_game = source_metadata.get(rel)
        if source_game is not None:
            game = ET.fromstring(ET.tostring(source_game, encoding="unicode"))
            path_node = game.find("path")
            if path_node is None:
                path_node = ET.SubElement(game, "path")
            path_node.text = f"./{rel}"
            root.append(game)
            continue
        game = ET.SubElement(root, "game")
        ET.SubElement(game, "path").text = f"./{rel}"
        ET.SubElement(game, "name").text = rom.stem
    tree = ET.ElementTree(root)
    try:
        ET.indent(tree, space="  ")
    except Exception:
        pass
    tree.write(system_dir / "gamelist.xml", encoding="utf-8", xml_declaration=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate per-Drone randomized Batocera ROM userdata.")
    parser.add_argument("--source", type=Path, default=Path(".github/data/roms"))
    parser.add_argument("--output", type=Path, default=Path(".github/generated"))
    parser.add_argument("--seed", default=None)
    parser.add_argument("--reset", action="store_true")
    parser.add_argument("--drone-count", type=int, default=4)
    parser.add_argument("--min-roms-per-system", type=int, default=1)
    parser.add_argument("--max-roms-per-system", type=int, default=4)
    args = parser.parse_args()

    source = args.source.resolve()
    output = args.output.resolve()
    if not source.exists():
        raise SystemExit(f"ROM source does not exist: {source}")
    if args.reset and output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True, exist_ok=True)

    seed = args.seed if args.seed is not None else hashlib.sha256(str(random.random()).encode()).hexdigest()[:12]
    systems = [p for p in sorted(source.iterdir(), key=lambda p: p.name.lower()) if p.is_dir()]
    pool = {system.name: [p for p in system.rglob("*") if is_rom(p, system)] for system in systems}
    pool = {system: files for system, files in pool.items() if files}
    if not pool:
        raise SystemExit(f"No ROM files found under {source}")

    letters = "abcdefghijklmnopqrstuvwxyz"
    for index in range(max(1, args.drone_count)):
        drone_name = f"drone-{letters[index]}"
        rng = random.Random(f"{seed}:{drone_name}")
        drone_rom_root = output / drone_name / "userdata" / "roms"
        if drone_rom_root.exists():
            shutil.rmtree(drone_rom_root)
        copied_by_system = {}
        for system, files in pool.items():
            if not files:
                continue
            max_count = min(len(files), max(args.min_roms_per_system, args.max_roms_per_system))
            min_count = min(max_count, max(1, args.min_roms_per_system))
            count = rng.randint(min_count, max_count)
            if len(files) > 1 and index % 2 == 1:
                count = max(1, min(count, len(files) - 1))
            selected = rng.sample(files, count)
            copied = []
            for src in selected:
                rel = src.relative_to(source / system)
                dest = drone_rom_root / system / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dest)
                copied.append(dest)
            copied_by_system[system] = copied
        for system, copied in copied_by_system.items():
            write_gamelist(drone_rom_root / system, copied, parse_source_metadata(source / system))
        total = sum(len(v) for v in copied_by_system.values())
        print(f"{drone_name}: generated {total} ROM files in {drone_rom_root}")

    print(f"Seed: {seed}")


if __name__ == "__main__":
    main()
