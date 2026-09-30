#!/usr/bin/env python3
"""Generate and verify Computer MCP artwork and exact consumer copies."""

import argparse
import hashlib
import json
import os
import plistlib
import struct
import subprocess
import tempfile
from pathlib import Path
from xml.etree import ElementTree
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
BRAND = ROOT / "Assets/Brand"
EXPORTS = BRAND / "Exports"
INPUTS = (
    "Assets/Brand/brand.json",
    "Assets/Brand/Sources/symbol.svg",
    "Assets/Brand/Sources/mark.svg.in",
    "Assets/Brand/Sources/app-icon.svg.in",
    "Assets/Brand/Sources/social.svg.in",
    "Assets/Brand/Sources/family.svg.in",
    "Scripts/brand.py",
    "Tools/Brand/check-consumer.py",
    "Tools/Brand/render.mjs",
    "Tools/Brand/package.json",
    "Tools/Brand/package-lock.json",
)
ICON_SIZES = {"icp4": 16, "icp5": 32, "icp6": 64, "ic07": 128,
              "ic08": 256, "ic09": 512, "ic10": 1024,
              "ic11": 32, "ic12": 64, "ic13": 256, "ic14": 512}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_brand():
    brand = json.loads((BRAND / "brand.json").read_text())
    assert brand["schema_version"] == 1, "Unsupported brand schema"
    assert set(brand["promise"]) == {"en", "zh-CN"}, "Promise locales differ"
    assert len({item["repository"] for item in brand["family"]}) == len(brand["family"]), "Duplicate family member"
    return brand


def source_hashes():
    return {name: digest((ROOT / name).read_bytes()) for name in INPUTS}


def vectors(brand):
    symbol = (BRAND / "Sources/symbol.svg").read_text()
    ElementTree.fromstring(symbol)
    symbol = symbol.split("</title>", 1)[1].rsplit("</svg>", 1)[0].strip()
    values = {**brand["colors"], "name": escape(brand["name"]), "symbol": symbol}

    def render(template, **overrides):
        text = (BRAND / f"Sources/{template}.svg.in").read_text()
        for key, value in {**values, **overrides}.items():
            text = text.replace("{{" + key + "}}", str(value))
        if "{{" in text:
            raise ValueError(f"Unresolved token in {template}")
        ElementTree.fromstring(text)
        return text.encode()

    output = {"symbol.svg": (BRAND / "Sources/symbol.svg").read_bytes(),
              "symbol-dark.svg": (BRAND / "Sources/symbol.svg").read_text().replace(
                  brand["colors"]["silver"], brand["colors"]["graphite"]).encode(),
              "mark.svg": render("mark"), "app-icon.svg": render("app-icon")}
    for locale, lines in {"en": ("Let ChatGPT", "use your local tools."),
                          "zh-CN": ("让 ChatGPT，", "用上你的本机工具。")}.items():
        joined = " ".join(lines) if locale == "en" else "".join(lines)
        if joined != brand["promise"][locale]:
            raise ValueError(f"Social line breaks do not match {locale} promise")
        output[f"social-{locale}.svg"] = render(
            "social", headline_label=escape(joined), headline_size=72,
            line1=escape(lines[0]), line2=escape(lines[1]),
            footer=escape(" · ".join(brand["pillars"])))
    for item in brand["family"]:
        output[f"{item['repository']}.svg"] = render(
            "family", integration=escape(item["name"]), role=escape(item["role"]))
    return output


def raster_specs(brand):
    specs = {"mark.png": ("mark.svg", 1024, 1024),
             "app-icon.png": ("app-icon.svg", 1024, 1024),
             "favicon.png": ("mark.svg", 32, 32),
             "apple-touch-icon.png": ("mark.svg", 180, 180)}
    for locale in brand["promise"]:
        specs[f"social-{locale}.png"] = (f"social-{locale}.svg", 1280, 640)
    for item in brand["family"]:
        repo = item["repository"]
        specs[f"{repo}.png"] = (f"{repo}.svg", 1280, 640)
    for size in sorted(set(ICON_SIZES.values())):
        specs[f"icon-{size}.png"] = ("app-icon.svg", size, size)
    return specs


def icns_bytes(directory):
    chunks = []
    for tag, size in ICON_SIZES.items():
        data = (directory / f"icon-{size}.png").read_bytes()
        chunks.append(tag.encode() + struct.pack(">I", len(data) + 8) + data)
    content = b"".join(chunks)
    return b"icns" + struct.pack(">I", len(content) + 8) + content


def generate():
    brand = read_brand()
    EXPORTS.mkdir(parents=True, exist_ok=True)
    for name, data in vectors(brand).items():
        (EXPORTS / name).write_bytes(data)
    with tempfile.TemporaryDirectory(prefix="computer-mcp-brand-") as directory:
        directory = Path(directory)
        jobs = [{"source": str(EXPORTS / source),
                 "destination": str(EXPORTS / name), "width": width, "height": height}
                for name, (source, width, height) in raster_specs(brand).items()]
        (directory / "jobs.json").write_text(json.dumps(jobs))
        subprocess.run(["node", str(ROOT / "Tools/Brand/render.mjs"),
                        str(directory / "jobs.json"), str(directory / "renderer.json")], check=True,
                       env={**os.environ, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"})
        renderer = json.loads((directory / "renderer.json").read_text())
    (EXPORTS / "AppIcon.icns").write_bytes(icns_bytes(EXPORTS))
    (EXPORTS / "check-consumer.py").write_bytes((ROOT / "Tools/Brand/check-consumer.py").read_bytes())
    names = sorted(set(vectors(brand)) | set(raster_specs(brand)) | {"AppIcon.icns", "check-consumer.py"})
    manifest = {"schema_version": 1, "inputs": source_hashes(), "renderer": renderer,
                "exports": {name: digest((EXPORTS / name).read_bytes()) for name in names}}
    (EXPORTS / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Generated {len(names)} brand delivery files")


def consumer_files(repo):
    if repo == "computer-mcp.github.io":
        return {**{f"public/brand/{name}": name for name in (
            "mark.svg", "mark.png", "favicon.png", "apple-touch-icon.png",
            "social-en.png", "social-zh-CN.png")},
            "scripts/check-brand.py": "check-consumer.py"}
    if repo in {item["repository"] for item in read_brand()["family"]}:
        return {"Documentation/Brand/header.svg": f"{repo}.svg",
                ".github/brand/social.png": f"{repo}.png",
                "Scripts/check-brand.py": "check-consumer.py"}
    if repo == ".github":
        return {"profile/brand/header.svg": "social-en.svg",
                "profile/brand/avatar.png": "mark.png",
                "Scripts/check-brand.py": "check-consumer.py"}
    raise ValueError(f"Unknown brand consumer: {repo}")


def consumer_lock(repo):
    return "public/brand/brand.lock.json" if repo == "computer-mcp.github.io" else "brand.lock.json"


def lock_record(repo):
    manifest = json.loads((EXPORTS / "manifest.json").read_text())
    return {"schema_version": 1, "source": "https://github.com/computer-mcp/computer-mcp",
            "revision": digest((EXPORTS / "manifest.json").read_bytes()),
            "consumer": repo, "name": read_brand()["name"],
            "promise": read_brand()["promise"],
            "files": {target: manifest["exports"][source]
                      for target, source in consumer_files(repo).items()}}


def sync(path):
    path = path.resolve()
    for target, source in consumer_files(path.name).items():
        destination = path / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes((EXPORTS / source).read_bytes())
    (path / consumer_lock(path.name)).write_text(json.dumps(lock_record(path.name), indent=2) + "\n")
    print(f"Synchronized {path.name}")


def check(consumers):
    brand = read_brand()
    manifest = json.loads((EXPORTS / "manifest.json").read_text())
    expected_names = set(vectors(brand)) | set(raster_specs(brand)) | {"AppIcon.icns", "check-consumer.py"}
    assert set(manifest["exports"]) == expected_names, "Export inventory differs"
    assert manifest["inputs"] == source_hashes(), "Brand source changed; regenerate exports"
    for name, expected in manifest["exports"].items():
        assert digest((EXPORTS / name).read_bytes()) == expected, f"Asset changed: {name}"
    for name, expected in vectors(brand).items():
        assert (EXPORTS / name).read_bytes() == expected, f"Vector drift: {name}"
    for name, (_, width, height) in raster_specs(brand).items():
        data = (EXPORTS / name).read_bytes()
        assert data[:8] == b"\x89PNG\r\n\x1a\n", f"Invalid PNG: {name}"
        assert struct.unpack(">II", data[16:24]) == (width, height), f"Wrong dimensions: {name}"
    assert (EXPORTS / "AppIcon.icns").read_bytes() == icns_bytes(EXPORTS), "Icon drift"
    assert (EXPORTS / "check-consumer.py").read_bytes() == (ROOT / "Tools/Brand/check-consumer.py").read_bytes(), "Consumer checker drift"
    for name, locale in (("README.md", "en"), ("README.zh-CN.md", "zh-CN")):
        text = (ROOT / name).read_text()
        assert brand["promise"][locale] in text, f"Promise missing: {name}"
        assert f"Assets/Brand/Exports/social-{locale}.png" in text, f"Artwork drift: {name}"
    plist = plistlib.loads((ROOT / "Resources/ComputerMCPApp/Info.plist").read_bytes())
    assert plist.get("CFBundleIconFile") == "AppIcon.icns", "App icon declaration missing"
    assert 'Assets/Brand/Exports/AppIcon.icns' in (ROOT / "Scripts/build-app.sh").read_text()
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    assert not any(name.startswith(".agent/") for name in tracked), "Local execution state is tracked"
    for legacy in ("mark.png", "social.png"):
        assert not (BRAND / legacy).exists(), f"Obsolete root asset: {legacy}"
    for path in consumers:
        path = path.resolve()
        lock = json.loads((path / consumer_lock(path.name)).read_text())
        assert lock == lock_record(path.name), f"Stale brand revision: {path.name}"
        for name, expected in lock["files"].items():
            assert digest((path / name).read_bytes()) == expected, f"Consumer drift: {path.name}/{name}"
    print(f"Brand contract and {len(expected_names)} assets verified; {len(consumers)} consumers checked")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("generate")
    sync_parser = sub.add_parser("sync")
    sync_parser.add_argument("consumer", type=Path)
    check_parser = sub.add_parser("check")
    check_parser.add_argument("--consumer", type=Path, action="append", default=[])
    args = parser.parse_args()
    if args.command == "generate":
        generate()
    elif args.command == "sync":
        sync(args.consumer)
    else:
        check(args.consumer)


if __name__ == "__main__":
    main()
