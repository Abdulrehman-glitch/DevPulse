# Development setup

## Prerequisites

Use 64-bit Windows with Git, Node/npm, Python, the Rust MSVC toolchain, Visual Studio C++ build tools, and Microsoft WebView2. The repository pins Node in `.node-version`, Python in `.python-version`, and Rust in `rust-toolchain.toml`; do not silently substitute newer toolchains for release evidence.

## Install locked dependencies

From the repository root:

```powershell
npm ci
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --no-deps -r requirements-ci.lock
.\.venv\Scripts\python.exe -m pip check
```

`requirements-ci.lock` is an exact Windows/Python closure and is installed with `--no-deps` so missing transitive pins fail visibly. Do not use global npm, pip, or Cargo installation for project audit tools.

## Run in development

```powershell
npm run versions:check
npm run dev
```

The Rust desktop starts the Python local core from `.venv` using the same bounded stdin/readiness protocol as packaged builds. Production data paths are used unless strict QA mode is configured; do not launch development against personal projects when testing scanner changes.

## Build the sidecar and frontend

```powershell
npm run assets:generate
npm run sidecar:build
npm run build
```

Generated sidecar and frontend output are ignored. See [TESTING.md](TESTING.md) before trusting a build and [RELEASE_PROCESS.md](RELEASE_PROCESS.md) before producing an installer.

