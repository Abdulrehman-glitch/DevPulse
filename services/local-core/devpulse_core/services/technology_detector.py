"""Bounded, read-only technology detection from repository-root metadata."""

from __future__ import annotations

import json
from pathlib import Path
from typing import ClassVar


class TechnologyDetector:
    MAX_CONFIG_BYTES = 256_000
    PRIMARY_ORDER: ClassVar[list[str]] = [
        "FastAPI",
        "Django",
        "Flask",
        "Tauri",
        "React",
        "Angular",
        "Vite",
        "Rust",
        "Java",
        "Kotlin",
        "Android",
        "Python",
        "Node.js",
        "TypeScript",
        "JavaScript",
        "Docker",
    ]

    def detect(self, root: Path) -> list[str]:
        try:
            names = {item.name.casefold(): item for item in root.iterdir()}
        except OSError:
            return []
        found: set[str] = set()
        if {
            "pyproject.toml",
            "requirements.txt",
            "setup.py",
            "setup.cfg",
            "pipfile",
        } & names.keys():
            found.add("Python")
        if "requirements.txt" in names:
            found.add("Python")
        if "cargo.toml" in names:
            found.add("Rust")
        tauri_directory = root / "src-tauri"
        tauri_config = tauri_directory / "tauri.conf.json"
        if "tauri.conf.json" in names or tauri_config.is_file():
            found.add("Tauri")
        if {"pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle"} & names.keys():
            found.add("Java")
        if "build.gradle.kts" in names or "settings.gradle.kts" in names:
            found.add("Kotlin")
        if (
            "androidmanifest.xml" in names
            or (root / "app" / "src" / "main" / "AndroidManifest.xml").exists()
        ):
            found.add("Android")
        if "package.json" in names:
            found.add("Node.js")
            package = self._read_json(names["package.json"])
            dependencies = {
                str(key).casefold()
                for section in ("dependencies", "devDependencies")
                for key in (package.get(section, {}) if isinstance(package, dict) else {})
            }
            self._detect_package_dependencies(dependencies, found)
        if {"tsconfig.json", "tsconfig.app.json"} & names.keys():
            found.add("TypeScript")
        if "package.json" in names and "TypeScript" not in found:
            found.add("JavaScript")
        if any(name.startswith("vite.config.") for name in names):
            found.add("Vite")
        if "angular.json" in names:
            found.update({"Angular", "TypeScript"})
        if any(
            name == "dockerfile" or name.startswith("docker-compose") or name.startswith("compose.")
            for name in names
        ):
            found.add("Docker")
        if {"azure-pipelines.yml", "azure-pipelines.yaml", "azure.yaml"} & names.keys():
            found.add("Azure deployment")
        workflows = root / ".github" / "workflows"
        try:
            if workflows.is_dir() and any(
                item.suffix.casefold() in {".yml", ".yaml"} for item in workflows.iterdir()
            ):
                found.add("GitHub Actions")
        except OSError:
            pass
        # Never inspect .env files. Only bounded public dependency manifests are read.
        text = "\n".join(
            self._read_text(names[name])
            for name in ("pyproject.toml", "requirements.txt", "setup.cfg")
            if name in names
        ).casefold()
        for marker, technology in {
            "fastapi": "FastAPI",
            "flask": "Flask",
            "django": "Django",
            "pytest": "pytest",
            "psycopg": "PostgreSQL",
            "asyncpg": "PostgreSQL",
            "pymongo": "MongoDB",
            "motor": "MongoDB",
        }.items():
            if marker in text:
                found.add(technology)
        return sorted(found, key=lambda item: (self._sort_index(item), item.casefold()))

    def dependency_manager(self, root: Path) -> str | None:
        names = self._root_names(root)
        for manager, files in (
            ("uv", {"uv.lock"}),
            ("Poetry", {"poetry.lock"}),
            ("npm", {"package-lock.json"}),
            ("pnpm", {"pnpm-lock.yaml"}),
            ("Yarn", {"yarn.lock"}),
            ("Cargo", {"cargo.lock"}),
            ("Gradle", {"gradlew", "build.gradle", "build.gradle.kts"}),
            ("Maven", {"pom.xml"}),
        ):
            if names & files:
                return manager
        if names & {"pyproject.toml", "requirements.txt", "pipfile"}:
            return "pip"
        return None

    def testing_framework(self, root: Path, technologies: list[str]) -> str | None:
        names = self._root_names(root)
        if "pytest" in technologies:
            return "pytest"
        if "Jest" in technologies:
            return "Jest"
        if "Vitest" in technologies:
            return "Vitest"
        if "Playwright" in technologies:
            return "Playwright"
        if names & {"pytest.ini", "tox.ini"}:
            return "pytest"
        return None

    def ci_provider(self, root: Path) -> str | None:
        names = self._root_names(root)
        workflows = root / ".github" / "workflows"
        try:
            if workflows.is_dir() and any(
                item.suffix.casefold() in {".yml", ".yaml"} for item in workflows.iterdir()
            ):
                return "GitHub Actions"
        except OSError:
            pass
        if names & {"azure-pipelines.yml", "azure-pipelines.yaml"}:
            return "Azure Pipelines"
        if ".gitlab-ci.yml" in names:
            return "GitLab CI"
        return None

    def deployment_indicators(self, root: Path) -> list[str]:
        names = self._root_names(root)
        indicators: list[str] = []
        if names & {"azure.yaml", "azure-pipelines.yml", "azure-pipelines.yaml"}:
            indicators.append("Azure")
        if names & {"vercel.json", "netlify.toml"}:
            indicators.append("Web hosting")
        if names & {
            "dockerfile",
            "docker-compose.yml",
            "docker-compose.yaml",
            "compose.yml",
            "compose.yaml",
        }:
            indicators.append("Container")
        return indicators

    @staticmethod
    def _root_names(root: Path) -> set[str]:
        try:
            return {item.name.casefold() for item in root.iterdir()}
        except OSError:
            return set()

    def primary(self, technologies: list[str]) -> str:
        return technologies[0] if technologies else "Unknown"

    def _sort_index(self, technology: str) -> int:
        try:
            return self.PRIMARY_ORDER.index(technology)
        except ValueError:
            return len(self.PRIMARY_ORDER)

    @staticmethod
    def _detect_package_dependencies(dependencies: set[str], found: set[str]) -> None:
        for package, technology in {
            "react": "React",
            "@angular/core": "Angular",
            "vite": "Vite",
            "typescript": "TypeScript",
            "jest": "Jest",
            "vitest": "Vitest",
            "pg": "PostgreSQL",
            "postgres": "PostgreSQL",
            "mongodb": "MongoDB",
            "mongoose": "MongoDB",
            "@playwright/test": "Playwright",
            "playwright": "Playwright",
        }.items():
            if package in dependencies:
                found.add(technology)

    def _read_text(self, path: Path) -> str:
        try:
            if path.stat().st_size > self.MAX_CONFIG_BYTES:
                return ""
            return path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return ""

    def _read_json(self, path: Path) -> object:
        try:
            return json.loads(self._read_text(path))
        except (json.JSONDecodeError, TypeError):
            return {}
