#!/usr/bin/env python3
"""Keep explicitly edited Xcode signing settings across XcodeGen runs.

Only local configuration overlays are written. Nothing accesses a keychain,
certificate, provisioning profile contents, or an Apple account.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess

TARGETS = {"WatchLink", "WatchLinkTests", "WatchLinkUITests"}
KEYS = {
    "DEVELOPMENT_TEAM", "CODE_SIGN_STYLE", "CODE_SIGN_IDENTITY",
    "PRODUCT_BUNDLE_IDENTIFIER", "PROVISIONING_PROFILE",
    "PROVISIONING_PROFILE_SPECIFIER",
}
ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z_0-9]*(?:\[[^\]\r\n]+\])?)\s*=\s*(.*)$")


def extract_overrides(project: dict) -> dict[tuple[str, str], dict[str, str]]:
    objects = project.get("objects", {})
    result = {}
    for target in objects.values():
        name = target.get("name")
        if target.get("isa") != "PBXNativeTarget" or name not in TARGETS:
            continue
        config_list = objects.get(target.get("buildConfigurationList"), {})
        for ref in config_list.get("buildConfigurations", []):
            config = objects.get(ref, {})
            config_name = config.get("name")
            if config_name not in {"Debug", "Release"}:
                continue
            kept = {}
            for key, value in config.get("buildSettings", {}).items():
                if key.split("[", 1)[0] not in KEYS:
                    continue
                if not ASSIGNMENT.match(key + "=") or not isinstance(value, (str, int)):
                    raise ValueError(f"Unsupported signing setting in {name}/{config_name}: {key}")
                text = str(value)
                if "\n" in text or "\r" in text:
                    raise ValueError(f"Multiline signing setting in {name}/{config_name}: {key}")
                # Quoting preserves spaces and literal strings; Xcode still expands $(...).
                kept[key] = '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'
            if kept:
                result[(name, config_name)] = kept
    return result


def write_overlays(config_dir: Path, overrides: dict) -> int:
    config_dir.mkdir(parents=True, exist_ok=True)
    updated = 0
    for (target, config), incoming in overrides.items():
        path = config_dir / f"{target}.{config}.local.xcconfig"
        existing = path.read_text(encoding="utf-8") if path.exists() else ""
        merged = {}
        for line in existing.splitlines():
            match = ASSIGNMENT.match(line.strip())
            if match:
                merged[match.group(1)] = match.group(2)
        if all(merged.get(key) == value for key, value in incoming.items()):
            continue
        merged.update(incoming)
        body = "// Local overrides imported from Xcode. Keep this file private to this checkout.\n"
        body += "// Global shared signing preferences may be set in Signing.local.xcconfig.\n"
        body += "".join(f"{key} = {value}\n" for key, value in sorted(merged.items()))
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(body, encoding="utf-8")
        temporary.replace(path)
        updated += 1
    return updated


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("config_directory", type=Path)
    args = parser.parse_args()
    if not args.project.exists():
        print("First generation: no existing Xcode signing settings to preserve.")
        return
    converted = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(args.project)],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
    )
    overrides = extract_overrides(json.loads(converted.stdout))
    count = write_overlays(args.config_directory, overrides)
    print(f"Preserved Xcode signing settings; {count} local configuration files updated.")


if __name__ == "__main__":
    main()
