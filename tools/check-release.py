#!/usr/bin/env python3
"""Fail before packaging if release metadata or the Git tag disagree."""
import argparse
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def match(path, pattern):
    result = re.search(pattern, (ROOT / path).read_text())
    if result is None:
        raise ValueError(f"Cannot read version from {path}")
    return result.group(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="Expected v-prefixed release tag")
    args = parser.parse_args()
    versions = {
        "Meson": match("meson.build", r"version:\s*'([^']+)'"),
        "AppStream": ET.parse(ROOT / "data/io.github.ChrisLauinger.MprisMiniPlayer.releases.xml")
            .getroot().find("release").attrib["version"],
        "Debian": match("debian/changelog", r"^mpris-miniplayer \(([^-)]+)-"),
        "manpage": match("debian/mpris-miniplayer.1", r'MPRIS MiniPlayer ([0-9.]+)"'),
        "RPM": match("rpm/mpris-miniplayer.spec", r"%global pkg_version ([^}\s]+)"),
    }
    if args.tag is not None:
        if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", args.tag):
            raise ValueError(f"Invalid release tag: {args.tag!r}")
        versions["Git tag"] = args.tag[1:]
    if len(set(versions.values())) != 1:
        raise ValueError("Release versions disagree: " + ", ".join(f"{k}={v}" for k, v in versions.items()))
    print(f"Release versions agree: {versions['Meson']}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, ET.ParseError, KeyError, AttributeError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
