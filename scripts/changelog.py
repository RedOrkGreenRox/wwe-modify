#!/usr/bin/env python3
# Extract a release's changelog from ui/assets/waywallen-ui.releases.xml as
# markdown bullets. The XML is an AppStream <release> fragment (no root element).
import sys
import xml.etree.ElementTree as ET

DEFAULT_XML = "ui/assets/waywallen-ui.releases.xml"


def extract(version: str, path: str) -> str:
    version = version.lstrip("v")
    with open(path, encoding="utf-8") as f:
        root = ET.fromstring(f"<releases>{f.read()}</releases>")

    for rel in root.findall("release"):
        if rel.get("version") != version:
            continue
        desc = rel.find("description")
        lines = []
        if desc is not None:
            lines = [(p.text or "").strip() for p in desc.findall("p")]
            lines = [l for l in lines if l]
        if not lines:
            return f"Release {version}."
        return "\n".join(f"- {l}" for l in lines)

    return f"Release {version}."


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: changelog.py <version> [releases.xml]")
    xml_path = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_XML
    print(extract(sys.argv[1], xml_path))
