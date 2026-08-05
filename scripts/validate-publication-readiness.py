"""Fail-closed local checks for the curated private-publication candidate."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path

REQUIRED_PATHS = {
    ".github/CODEOWNERS",
    ".github/ISSUE_TEMPLATE/bug_report.yml",
    ".github/ISSUE_TEMPLATE/config.yml",
    ".github/ISSUE_TEMPLATE/documentation.yml",
    ".github/ISSUE_TEMPLATE/feature_request.yml",
    ".github/ISSUE_TEMPLATE/performance_issue.yml",
    ".github/pull_request_template.md",
    "CHANGELOG.md",
    "CODE_OF_CONDUCT.md",
    "CONTRIBUTING.md",
    "GOVERNANCE.md",
    "LICENSE",
    "NOTICE",
    "PUBLICATION_STATUS.md",
    "README.md",
    "ROADMAP.md",
    "SECURITY.md",
    "SUPPORT.md",
    "THIRD_PARTY_NOTICES.md",
    "TRADEMARKS.md",
    "docs/README.md",
    "docs/architecture/LOCAL_CORE_STARTUP.md",
    "docs/architecture/README.md",
    "docs/architecture/SYSTEM_OVERVIEW.md",
    "docs/development/COMMIT_CONVENTIONS.md",
    "docs/development/RELEASE_PROCESS.md",
    "docs/development/SETUP.md",
    "docs/development/TESTING.md",
    "docs/legal/ASSET_PROVENANCE.md",
    "docs/legal/DEPENDENCY_REVIEW.md",
    "docs/legal/LICENSING_MODEL.md",
    "docs/legal/dependency-licences.json",
    "docs/security/THREAT_MODEL.md",
}

PROHIBITED_SUFFIXES = {
    ".7z",
    ".db",
    ".dll",
    ".dmp",
    ".dump",
    ".exe",
    ".gz",
    ".lib",
    ".log",
    ".msi",
    ".msix",
    ".pdb",
    ".rar",
    ".sqlite",
    ".sqlite3",
    ".tar",
    ".zip",
}

PROVIDER_SECRET = re.compile(
    rb"(?i)(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|"
    rb"AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|"
    rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)"
)
CONSUMER_EMAIL = re.compile(
    rb"(?i)[A-Z0-9._%+-]+@(gmail|outlook|hotmail|yahoo|icloud|protonmail|proton)\.[A-Z]{2,}"
)
REAL_WINDOWS_USER_PATH = re.compile(rb"(?i)[A-Z]:\\Users\\(?!fixture(?:\\|$)|Private(?:\\|$))")
REAL_UNIX_USER_PATH = re.compile(rb"/(?:home|Users)/(?!fixture(?:/|$)|private(?:/|$))[^/\s]+/")
PRIVATE_SOURCE_PATH = re.compile(rb"(?i)C:\\DevPulse(?:\\|$)")


def run(root: Path, *arguments: str, text: bool = True) -> str | bytes:
    completed = subprocess.run(
        ["git", "-C", str(root), *arguments],
        check=True,
        capture_output=True,
        text=text,
    )
    return completed.stdout


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def history(root: Path) -> tuple[set[str], dict[str, bytes], int]:
    commits = str(run(root, "rev-list", "--all")).splitlines()
    paths: set[str] = set()
    blob_ids: set[str] = set()
    for commit in commits:
        tree = bytes(run(root, "ls-tree", "-rz", "--full-tree", commit, text=False))
        for entry in tree.split(b"\0"):
            if not entry:
                continue
            metadata, raw_path = entry.split(b"\t", 1)
            mode, kind, object_id = metadata.decode("ascii").split()
            path = raw_path.decode("utf-8", errors="strict")
            paths.add(path)
            if kind == "blob":
                blob_ids.add(object_id)
            if mode not in {"100644", "100755"}:
                raise RuntimeError(f"Non-regular Git mode found at {path}.")
    blobs = {
        object_id: bytes(run(root, "cat-file", "blob", object_id, text=False))
        for object_id in sorted(blob_ids)
    }
    return paths, blobs, len(commits)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    errors: list[str] = []

    if str(run(root, "branch", "--show-current")).strip() != "main":
        fail(errors, "The current branch is not main.")
    if str(run(root, "status", "--porcelain=v1", "--untracked-files=all")).strip():
        fail(errors, "The curated worktree is not clean.")
    branches = str(run(root, "for-each-ref", "--format=%(refname)", "refs/heads")).splitlines()
    if branches != ["refs/heads/main"]:
        fail(errors, "Unexpected local branches exist.")
    if str(run(root, "tag", "--list")).strip():
        fail(errors, "A tag exists in the curated repository.")
    if str(run(root, "remote")).strip():
        fail(errors, "A remote exists before the local publication gate.")

    paths, blobs, commit_count = history(root)
    missing = sorted(REQUIRED_PATHS - paths)
    if missing:
        fail(errors, "Required repository files are missing: " + ", ".join(missing))
    for path in sorted(paths):
        lower = path.lower()
        if lower.startswith(".github/workflows/"):
            fail(errors, "A workflow exists in curated history.")
        if lower.startswith(("evidence/", "logs/", "data/")):
            fail(errors, f"Runtime or generated evidence is tracked: {path}")
        if Path(lower).suffix in PROHIBITED_SUFFIXES:
            fail(errors, f"A prohibited artifact type is tracked: {path}")
        if lower in {
            "docs/assets/screenshots/overview-beta1.png",
            "sbom.json",
            "release_notes.md",
        }:
            fail(errors, f"An excluded pre-public artifact exists in history: {path}")

    scans = {
        "providerCredential": PROVIDER_SECRET,
        "consumerEmail": CONSUMER_EMAIL,
        "realWindowsUserPath": REAL_WINDOWS_USER_PATH,
        "realUnixUserPath": REAL_UNIX_USER_PATH,
        "protectedSourcePath": PRIVATE_SOURCE_PATH,
    }
    scan_hits = {name: 0 for name in scans}
    for content in blobs.values():
        for name, pattern in scans.items():
            if pattern.search(content):
                scan_hits[name] += 1
    for name, count in scan_hits.items():
        if count:
            fail(errors, f"Complete-history {name} scan found {count} affected blob(s).")

    identities = str(run(root, "log", "--all", "--format=%ae%n%ce")).splitlines()
    approved_email = "172409283+Abdulrehman-glitch@users.noreply.github.com"
    if not identities or any(value != approved_email for value in identities):
        fail(errors, "Commit history contains an unapproved author or committer identity.")

    root_body = str(
        run(
            root,
            "show",
            "-s",
            "--format=%B",
            str(run(root, "rev-list", "--max-parents=0", "HEAD")).strip(),
        )
    )
    for statement in [
        "curated pre-public baseline",
        "Historical development remains preserved privately",
        "does not recreate historical release provenance",
    ]:
        if statement.lower() not in root_body.lower():
            fail(errors, "Root commit does not contain the required provenance statement.")

    dependency_data = json.loads(
        (root / "docs/legal/dependency-licences.json").read_text(encoding="utf-8")
    )
    blocking = {
        "RUNTIME REVIEW REQUIRED",
        "REPLACE BEFORE PUBLICATION",
        "TOOLING LIMITATION",
    }
    if any(item["classification"] in blocking for item in dependency_data["components"]):
        fail(errors, "Dependency inventory contains a publication-blocking classification.")
    if dependency_data["summary"]["missingDeclaredLicense"] != 0:
        fail(errors, "Dependency inventory contains a missing licence declaration.")

    lifecycle = (root / "apps/desktop/src-tauri/src/lifecycle.rs").read_text(encoding="utf-8")
    python_main = (root / "services/local-core/devpulse_core/main.py").read_text(encoding="utf-8")
    if '"--token".to_string()' in lifecycle or '"--handshake-file".to_string()' in lifecycle:
        fail(errors, "Rust process arguments retain an obsolete secret option.")
    if "handshake_file" in python_main or 'add_argument("--token"' in python_main:
        fail(errors, "Python startup retains an obsolete secret argument or disk handshake.")

    license_text = (root / "LICENSE").read_text(encoding="utf-8")
    if "Apache License" not in license_text or "Version 2.0, January 2004" not in license_text:
        fail(errors, "Apache License 2.0 text is absent.")
    if (root / ".github/workflows").exists():
        fail(errors, "A local workflow directory exists.")
    for path in root.rglob("*"):
        if path.is_symlink() or path.is_junction():
            fail(errors, "A filesystem link or junction exists in the staging tree.")
            break

    version = subprocess.run(
        ["node", "scripts/sync-version.mjs", "--check"],
        cwd=root,
        capture_output=True,
        text=True,
    )
    if version.returncode != 0:
        fail(errors, "Version locations are not synchronized.")
    diff_check = subprocess.run(
        ["git", "diff", "--check"], cwd=root, capture_output=True, text=True
    )
    if diff_check.returncode != 0:
        fail(errors, "Git diff whitespace validation failed.")

    result = {
        "schemaVersion": 1,
        "verdict": "PASS" if not errors else "FAIL",
        "commitCount": commit_count,
        "historyPathCount": len(paths),
        "historyBlobCount": len(blobs),
        "scanHits": scan_hits,
        "errors": errors,
    }
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(f"Publication readiness validation: {result['verdict']}")
        for error in errors:
            print(f"- {error}")
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
