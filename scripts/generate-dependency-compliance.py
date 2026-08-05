"""Generate deterministic dependency licence evidence for npm, Cargo, and Python."""

# ruff: noqa: E501

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
import re
import subprocess
import tomllib
from collections import deque
from pathlib import Path
from typing import Any

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name

SCHEMA_VERSION = 1
TARGET = "x86_64-pc-windows-msvc"
MISSING_LICENSES = {"", "UNKNOWN", "NOASSERTION", "NONE", "N/A"}
RESTRICTIVE_MARKERS = ("AGPL", "SSPL", "BUSL", "BSL-1.1", "ELASTIC", "COMMONS CLAUSE")
COPYLEFT_MARKERS = ("GPL-", "LGPL-", "EUPL-", "CDDL-")
NOTICE_MARKERS = ("MPL-", "CC-BY-", "OFL-")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def license_files(directory: Path, candidates: list[Path] | None = None) -> list[dict[str, str]]:
    if candidates is None:
        candidates = [
            path
            for path in directory.iterdir()
            if path.is_file()
            and re.match(r"(?i)^(licen[cs]e|copying|notice|copyright)([._-].*)?$", path.name)
        ]
    evidence: list[dict[str, str]] = []
    for path in sorted({path.resolve() for path in candidates if path.is_file()}):
        evidence.append({"name": path.name, "sha256": sha256(path)})
    return evidence


def classify(license_expression: str, scope: str) -> str:
    normalized = license_expression.strip().upper()
    if normalized in MISSING_LICENSES:
        return "RUNTIME REVIEW REQUIRED" if scope == "runtime" else "TOOLING LIMITATION"
    if any(marker in normalized for marker in RESTRICTIVE_MARKERS):
        return "REPLACE BEFORE PUBLICATION" if scope == "runtime" else "DEVELOPMENT-ONLY"
    if any(marker in normalized for marker in COPYLEFT_MARKERS):
        return "RUNTIME REVIEW REQUIRED" if scope == "runtime" else "DEVELOPMENT-ONLY"
    if scope in {"development", "build"}:
        return "DEVELOPMENT-ONLY"
    if any(marker in normalized for marker in NOTICE_MARKERS):
        return "REVIEWED WITH NOTICE"
    return "RESOLVED COMPATIBLE"


def npm_name(lock_path: str) -> str:
    return lock_path.rsplit("node_modules/", 1)[-1]


def npm_inventory(root: Path) -> list[dict[str, Any]]:
    lock = json.loads((root / "package-lock.json").read_text(encoding="utf-8"))
    direct_runtime: set[str] = set()
    direct_development: set[str] = set()
    for manifest_path in [
        root / "package.json",
        root / "apps/desktop/package.json",
        root / "packages/shared-types/package.json",
    ]:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        direct_runtime.update(manifest.get("dependencies", {}))
        direct_development.update(manifest.get("devDependencies", {}))

    components: list[dict[str, Any]] = []
    for lock_path, details in lock["packages"].items():
        if not lock_path.startswith("node_modules/") or details.get("link"):
            continue
        name = details.get("name") or npm_name(lock_path)
        package_dir = root / lock_path
        package_manifest: dict[str, Any] = {}
        manifest_path = package_dir / "package.json"
        if manifest_path.is_file():
            package_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        declared = str(details.get("license") or package_manifest.get("license") or "NOASSERTION")
        scope = "development" if details.get("dev") else "runtime"
        if details.get("devOptional") and scope == "runtime":
            scope = "development"
        direct = name in direct_runtime or name in direct_development
        components.append(
            {
                "ecosystem": "npm",
                "name": name,
                "version": str(
                    details.get("version") or package_manifest.get("version") or "UNKNOWN"
                ),
                "scope": scope,
                "relationship": "direct" if direct else "transitive",
                "declaredLicense": declared,
                "classification": classify(declared, scope),
                "resolvedSource": details.get("resolved") or package_manifest.get("homepage"),
                "integrity": details.get("integrity"),
                "licenseFiles": license_files(package_dir) if package_dir.is_dir() else [],
                "deprecated": bool(details.get("deprecated") or package_manifest.get("deprecated")),
            }
        )
    return sorted(components, key=lambda item: (item["name"].lower(), item["version"]))


def cargo_metadata(root: Path) -> dict[str, Any]:
    command = [
        "cargo",
        "metadata",
        "--locked",
        "--filter-platform",
        TARGET,
        "--format-version",
        "1",
        "--manifest-path",
        str(root / "apps/desktop/src-tauri/Cargo.toml"),
    ]
    environment = os.environ.copy()
    completed = subprocess.run(
        command,
        cwd=root,
        env=environment,
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    return json.loads(completed.stdout)


def cargo_inventory(root: Path) -> list[dict[str, Any]]:
    metadata = cargo_metadata(root)
    packages = {package["id"]: package for package in metadata["packages"]}
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    root_id = metadata["resolve"]["root"]
    scopes: dict[str, set[str]] = {root_id: {"runtime"}}
    queue: deque[str] = deque([root_id])
    direct_ids: set[str] = set()
    while queue:
        parent_id = queue.popleft()
        parent_scopes = scopes[parent_id]
        for dependency in nodes.get(parent_id, {}).get("deps", []):
            dependency_id = dependency["pkg"]
            if parent_id == root_id:
                direct_ids.add(dependency_id)
            edge_kinds = {kind.get("kind") or "normal" for kind in dependency.get("dep_kinds", [])}
            next_scopes: set[str] = set()
            for parent_scope in parent_scopes:
                for edge_kind in edge_kinds or {"normal"}:
                    if edge_kind == "dev":
                        next_scopes.add("development")
                    elif edge_kind == "build" or parent_scope == "build":
                        next_scopes.add("build")
                    else:
                        next_scopes.add(parent_scope)
            previous = scopes.setdefault(dependency_id, set())
            new = next_scopes - previous
            if new:
                previous.update(new)
                queue.append(dependency_id)

    lock = tomllib.loads((root / "apps/desktop/src-tauri/Cargo.lock").read_text(encoding="utf-8"))
    checksums = {
        (package["name"], str(package["version"]), package.get("source")): package.get("checksum")
        for package in lock["package"]
    }
    priority = {"runtime": 0, "build": 1, "development": 2}
    components: list[dict[str, Any]] = []
    for package_id, package_scopes in scopes.items():
        if package_id == root_id:
            continue
        package = packages[package_id]
        scope = min(package_scopes, key=priority.__getitem__)
        license_expression = package.get("license") or "NOASSERTION"
        manifest_directory = Path(package["manifest_path"]).parent
        candidates: list[Path] = []
        if package.get("license_file"):
            candidates.append(manifest_directory / package["license_file"])
        else:
            candidates = [
                path
                for path in manifest_directory.iterdir()
                if path.is_file()
                and re.match(r"(?i)^(licen[cs]e|copying|notice|copyright)([._-].*)?$", path.name)
            ]
        source = package.get("source")
        components.append(
            {
                "ecosystem": "cargo",
                "name": package["name"],
                "version": package["version"],
                "scope": scope,
                "relationship": "direct" if package_id in direct_ids else "transitive",
                "declaredLicense": license_expression,
                "classification": classify(license_expression, scope),
                "resolvedSource": source,
                "integrity": checksums.get((package["name"], package["version"], source)),
                "licenseFiles": license_files(manifest_directory, candidates),
                "deprecated": False,
            }
        )
    return sorted(components, key=lambda item: (item["name"].lower(), item["version"]))


def python_direct_requirements(root: Path) -> tuple[list[Requirement], set[str]]:
    project = tomllib.loads((root / "pyproject.toml").read_text(encoding="utf-8"))["project"]
    runtime = [Requirement(value) for value in project["dependencies"]]
    development = {
        canonicalize_name(Requirement(value).name)
        for value in project.get("optional-dependencies", {}).get("dev", [])
    }
    return runtime, development


def python_runtime_closure(root: Path) -> tuple[set[str], set[str]]:
    distributions = {
        canonicalize_name(distribution.metadata["Name"]): distribution
        for distribution in importlib.metadata.distributions()
        if distribution.metadata.get("Name")
    }
    direct_requirements, development = python_direct_requirements(root)
    direct_runtime = {canonicalize_name(requirement.name) for requirement in direct_requirements}
    requested_extras: dict[str, set[str]] = {
        canonicalize_name(requirement.name): set(requirement.extras)
        for requirement in direct_requirements
    }
    runtime = set(direct_runtime)
    queue: deque[str] = deque(sorted(direct_runtime))
    while queue:
        name = queue.popleft()
        distribution = distributions.get(name)
        if distribution is None:
            continue
        extras = requested_extras.get(name, set())
        for value in distribution.requires or []:
            requirement = Requirement(value)
            contexts = ["", *sorted(extras)]
            if requirement.marker and not any(
                requirement.marker.evaluate({"extra": extra}) for extra in contexts
            ):
                continue
            dependency = canonicalize_name(requirement.name)
            requested_extras.setdefault(dependency, set()).update(requirement.extras)
            if dependency not in runtime:
                runtime.add(dependency)
                queue.append(dependency)
    return runtime, development


def python_license(distribution: importlib.metadata.Distribution) -> str:
    metadata = distribution.metadata
    expression = metadata.get("License-Expression")
    if expression:
        return expression.strip()
    license_value = (metadata.get("License") or "").strip()
    if license_value and len(license_value) < 200 and "\n" not in license_value:
        return license_value
    classifiers = metadata.get_all("Classifier") or []
    approved = [value.rsplit(" :: ", 1)[-1] for value in classifiers if "License ::" in value]
    return " OR ".join(sorted(set(approved))) or "NOASSERTION"


def python_inventory(root: Path) -> list[dict[str, Any]]:
    runtime, direct_development = python_runtime_closure(root)
    direct_runtime, _ = python_direct_requirements(root)
    direct_runtime_names = {canonicalize_name(requirement.name) for requirement in direct_runtime}
    components: list[dict[str, Any]] = []
    for distribution in importlib.metadata.distributions():
        raw_name = distribution.metadata.get("Name")
        if not raw_name:
            continue
        name = canonicalize_name(raw_name)
        scope = "runtime" if name in runtime else "development"
        direct = name in direct_runtime_names or name in direct_development
        declared = python_license(distribution)
        declared_files = {
            Path(value).name.lower()
            for value in (distribution.metadata.get_all("License-File") or [])
        }
        candidates = [
            Path(distribution.locate_file(value))
            for value in (distribution.files or [])
            if "licenses" in {part.lower() for part in Path(value).parts}
            or Path(value).name.lower() in declared_files
        ]
        project_urls = distribution.metadata.get_all("Project-URL") or []
        source_url = next(
            (value.split(",", 1)[1].strip() for value in project_urls if "," in value),
            distribution.metadata.get("Home-page"),
        )
        components.append(
            {
                "ecosystem": "python",
                "name": raw_name,
                "version": distribution.version,
                "scope": scope,
                "relationship": "direct" if direct else "transitive",
                "declaredLicense": declared,
                "classification": classify(declared, scope),
                "resolvedSource": source_url,
                "integrity": None,
                "licenseFiles": license_files(root, candidates),
                "deprecated": False,
            }
        )
    return sorted(components, key=lambda item: (item["name"].lower(), item["version"]))


def summary(components: list[dict[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {
        "total": len(components),
        "byEcosystem": {},
        "byScope": {},
        "byClassification": {},
        "missingDeclaredLicense": 0,
    }
    for component in components:
        for field, target in [
            ("ecosystem", "byEcosystem"),
            ("scope", "byScope"),
            ("classification", "byClassification"),
        ]:
            key = component[field]
            result[target][key] = result[target].get(key, 0) + 1
        if component["declaredLicense"].upper() in MISSING_LICENSES:
            result["missingDeclaredLicense"] += 1
    for target in ["byEcosystem", "byScope", "byClassification"]:
        result[target] = dict(sorted(result[target].items()))
    return result


def markdown_review(data: dict[str, Any]) -> str:
    counts = data["summary"]
    unresolved = [
        component
        for component in data["components"]
        if component["classification"]
        in {"RUNTIME REVIEW REQUIRED", "REPLACE BEFORE PUBLICATION", "TOOLING LIMITATION"}
    ]
    lines = [
        "# Dependency review",
        "",
        "This review is generated deterministically from the committed npm and Cargo lockfiles, "
        "Cargo metadata filtered for the Windows target, and installed Python distribution metadata "
        "from the pinned validation environment.",
        "",
        "## Summary",
        "",
        f"- Components: {counts['total']}",
        f"- npm: {counts['byEcosystem'].get('npm', 0)}",
        f"- Cargo: {counts['byEcosystem'].get('cargo', 0)}",
        f"- Python: {counts['byEcosystem'].get('python', 0)}",
        f"- Runtime: {counts['byScope'].get('runtime', 0)}",
        f"- Build/development: {counts['byScope'].get('build', 0) + counts['byScope'].get('development', 0)}",
        "",
        "The old aggregate UNKNOWN result is not used. Every component has an individual declaration, "
        "scope, evidence hash where available, and publication classification in "
        "`dependency-licences.json`.",
        "",
        "## Classification policy",
        "",
        "- `RESOLVED COMPATIBLE`: a declared permissive licence compatible with distribution under the project licence.",
        "- `REVIEWED WITH NOTICE`: a compatible licence with specific attribution or file-level obligations recorded in notices.",
        "- `DEVELOPMENT-ONLY`: not part of the shipped runtime graph for the supported Windows target.",
        "- `RUNTIME REVIEW REQUIRED`: unresolved or potentially copyleft runtime terms; publication is blocked until resolved.",
        "- `REPLACE BEFORE PUBLICATION`: incompatible or source-available runtime terms; publication is blocked.",
        "- `TOOLING LIMITATION`: metadata is insufficient for a non-runtime tool and is listed explicitly.",
        "",
        "## Items requiring attention",
        "",
    ]
    if unresolved:
        lines.extend(
            f"- `{item['ecosystem']}:{item['name']}@{item['version']}` — "
            f"{item['classification']}; declared `{item['declaredLicense']}`."
            for item in unresolved
        )
    else:
        lines.append(
            "No component remains in `RUNTIME REVIEW REQUIRED`, `REPLACE BEFORE PUBLICATION`, or `TOOLING LIMITATION`."
        )
    lines.extend(
        [
            "",
            "## Review conclusions",
            "",
            "The generated inventory is a technical compliance aid, not legal advice. Permissive dependencies "
            "remain subject to their own notice conditions. MPL-2.0, CC-BY, and similar entries are retained "
            "with explicit notice classification rather than being described as unknown. Build and development "
            "tools are separated from the runtime graph.",
            "",
            "Before a release, regenerate this inventory after any lockfile change, review the classification "
            "diff, run all ecosystem vulnerability checks, and include `THIRD_PARTY_NOTICES.md` with distributed "
            "artifacts. The installer must not ship any component that is absent from the locked inventory.",
            "",
        ]
    )
    return "\n".join(lines)


def notices(data: dict[str, Any]) -> str:
    lines = [
        "# Third-party notices",
        "",
        "DevPulse includes or depends on the third-party components listed below. Each component remains "
        "subject to its declared licence. Licence-file SHA-256 values identify the exact notice text reviewed "
        "from the locked package source; the machine-readable inventory records those hashes.",
        "",
        "This file is generated by `scripts/generate-dependency-compliance.py`. Do not edit it manually.",
        "",
        "| Ecosystem | Component | Version | Scope | Licence | Classification |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for item in data["components"]:
        values = [
            item["ecosystem"],
            item["name"].replace("|", "\\|"),
            item["version"],
            item["scope"],
            item["declaredLicense"].replace("|", "\\|"),
            item["classification"],
        ]
        lines.append("| " + " | ".join(values) + " |")
    lines.extend(
        [
            "",
            "The project’s Apache-2.0 licence does not replace these third-party terms. Source URLs, integrity "
            "values, relationship, deprecation flags, and licence-file hashes are in "
            "`docs/legal/dependency-licences.json`.",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    components = npm_inventory(root) + cargo_inventory(root) + python_inventory(root)
    components.sort(key=lambda item: (item["ecosystem"], item["name"].lower(), item["version"]))
    data = {
        "schemaVersion": SCHEMA_VERSION,
        "target": TARGET,
        "inputs": {
            "cargoLockSha256": sha256(root / "apps/desktop/src-tauri/Cargo.lock"),
            "npmLockSha256": sha256(root / "package-lock.json"),
            "pythonLockSha256": sha256(root / "requirements-ci.lock"),
        },
        "summary": summary(components),
        "components": components,
    }
    outputs = {
        root / "docs/legal/dependency-licences.json": json.dumps(
            data, indent=2, sort_keys=True, ensure_ascii=False
        )
        + "\n",
        root / "docs/legal/DEPENDENCY_REVIEW.md": markdown_review(data),
        root / "THIRD_PARTY_NOTICES.md": notices(data),
    }
    stale: list[str] = []
    for path, content in outputs.items():
        if args.check:
            if not path.is_file() or path.read_text(encoding="utf-8") != content:
                stale.append(path.relative_to(root).as_posix())
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8", newline="\n")
    if stale:
        raise SystemExit("Dependency compliance outputs are stale: " + ", ".join(stale))
    if not args.check:
        print(json.dumps(data["summary"], sort_keys=True))


if __name__ == "__main__":
    main()
