"""Generate a small CycloneDX inventory from committed dependency lockfiles."""

from __future__ import annotations

import json
import re
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()


def component(
    name: str, version: str, kind: str, purl: str | None = None, license_: str = "UNKNOWN"
) -> dict[str, object]:
    result: dict[str, object] = {
        "type": kind,
        "name": name,
        "version": version,
        "licenses": [{"license": {"id": license_}}],
        "properties": [{"name": "devpulse:license-review", "value": "required"}],
    }
    if purl:
        result["purl"] = purl
    return result


def npm_components() -> list[dict[str, object]]:
    lock = json.loads((ROOT / "package-lock.json").read_text(encoding="utf-8"))
    items: list[dict[str, object]] = []
    for key, value in lock.get("packages", {}).items():
        if not key.startswith("node_modules/") or not isinstance(value, dict):
            continue
        name = key.removeprefix("node_modules/")
        version = value.get("version")
        if not isinstance(version, str):
            continue
        license_value = value.get("license", "UNKNOWN")
        license_id = license_value if isinstance(license_value, str) else "UNKNOWN"
        encoded = name.replace("/", "%2F")
        items.append(
            component(name, version, "library", f"pkg:npm/{encoded}@{version}", license_id)
        )
    return items


def cargo_components() -> list[dict[str, object]]:
    lock = tomllib.loads((ROOT / "apps/desktop/src-tauri/Cargo.lock").read_text(encoding="utf-8"))
    items: list[dict[str, object]] = []
    for package in lock.get("package", []):
        if not isinstance(package, dict) or not isinstance(package.get("name"), str):
            continue
        name = package["name"]
        version = str(package.get("version", "unknown"))
        items.append(component(name, version, "library", f"pkg:cargo/{name}@{version}"))
    return items


def python_components() -> list[dict[str, object]]:
    items: list[dict[str, object]] = []
    pattern = re.compile(r"^([A-Za-z0-9_.-]+)==([^\\s]+)$")
    for raw in (ROOT / "requirements-ci.lock").read_text(encoding="utf-8").splitlines():
        match = pattern.match(raw.strip())
        if not match:
            continue
        name, version = match.groups()
        items.append(component(name, version, "library", f"pkg:pypi/{name.lower()}@{version}"))
    return items


def main() -> None:
    components = npm_components() + cargo_components() + python_components()
    components.extend(
        [
            component("Tauri 2 NSIS bundle", VERSION, "application"),
            component("WebView2 Evergreen runtime", "host-provided", "framework"),
        ]
    )
    bom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": f"urn:uuid:devpulse-{VERSION}",
        "version": 1,
        "metadata": {
            "component": {"type": "application", "name": "DevPulse", "version": VERSION},
            "properties": [
                {
                    "name": "devpulse:generated-from",
                    "value": "package-lock.json, Cargo.lock, requirements-ci.lock",
                },
                {
                    "name": "devpulse:license-status",
                    "value": "engineering inventory; legal review required",
                },
            ],
        },
        "components": sorted(components, key=lambda item: (str(item["type"]), str(item["name"]))),
    }
    destination = ROOT / "sbom.json"
    destination.write_text(json.dumps(bom, indent=2) + "\n", encoding="utf-8")
    print(f"Generated {destination} with {len(components)} components.")


if __name__ == "__main__":
    main()
