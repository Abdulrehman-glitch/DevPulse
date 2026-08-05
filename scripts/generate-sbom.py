"""Generate a deterministic CycloneDX SBOM from the reviewed dependency inventory."""

from __future__ import annotations

import json
import os
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
INVENTORY = ROOT / "docs/legal/dependency-licences.json"


def package_url(ecosystem: str, name: str, version: str) -> str:
    encoded_name = quote(name, safe="/")
    package_type = {"cargo": "cargo", "npm": "npm", "python": "pypi"}[ecosystem]
    return f"pkg:{package_type}/{encoded_name}@{quote(version, safe='')}"


def component(item: dict[str, object]) -> dict[str, object]:
    ecosystem = str(item["ecosystem"])
    name = str(item["name"])
    version = str(item["version"])
    purl = package_url(ecosystem, name, version)
    properties = [
        {"name": "devpulse:ecosystem", "value": ecosystem},
        {"name": "devpulse:scope", "value": str(item["scope"])},
        {"name": "devpulse:relationship", "value": str(item["relationship"])},
        {"name": "devpulse:license-classification", "value": str(item["classification"])},
    ]
    integrity = item.get("integrity")
    if integrity:
        properties.append({"name": "devpulse:locked-integrity", "value": str(integrity)})
    return {
        "type": "library",
        "bom-ref": purl,
        "name": name,
        "version": version,
        "purl": purl,
        "licenses": [{"expression": str(item["declaredLicense"])}],
        "properties": properties,
    }


def main() -> None:
    inventory = json.loads(INVENTORY.read_text(encoding="utf-8"))
    components = [component(item) for item in inventory["components"]]
    components.sort(key=lambda item: (str(item["purl"]), str(item["version"])))
    bom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "bom-ref": f"pkg:generic/devpulse@{VERSION}",
                "name": "DevPulse",
                "version": VERSION,
                "licenses": [{"license": {"id": "Apache-2.0"}}],
            },
            "properties": [
                {
                    "name": "devpulse:generated-from",
                    "value": "docs/legal/dependency-licences.json",
                },
                {
                    "name": "devpulse:inventory-schema-version",
                    "value": str(inventory["schemaVersion"]),
                },
                {"name": "devpulse:target", "value": str(inventory["target"])},
            ],
        },
        "components": components,
    }
    configured = os.environ.get("DEVPULSE_SBOM_OUTPUT")
    destination = Path(configured) if configured else ROOT / ".qa-runtime/sbom.cdx.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        json.dumps(bom, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(f"Generated {destination} with {len(components)} components.")


if __name__ == "__main__":
    main()
