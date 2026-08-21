# Windows x64 compatibility contract

## Supported release claim

DevPulse `0.3.x` supports only Windows x64 and requires the Microsoft WebView2 Evergreen Runtime to be present before installation. The installer is per-user, declares `asInvoker`, installs no Windows service, and does not download or bootstrap system prerequisites. macOS, Linux, Windows Arm, and 32-bit Windows are outside the support claim.

Automated clean-machine qualification covers the standard GitHub-hosted `windows-2022` and `windows-2025` x64 images. GitHub documents these labels as standard runners and states that standard hosted runners are free and unlimited for public repositories in [Choosing the runner for a job](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job). These Windows Server images are the tested environment; the matrix does not manufacture a claim for every consumer Windows edition or build.

## Bounded automated matrix

The manual `.github/workflows/windows-compatibility.yml` workflow accepts one full 40-character commit SHA and checks out that exact commit beneath a path containing spaces and non-ASCII characters. It has read-only repository permission, a 90-minute job timeout, immutable action pins, standard runners only, and no artifact upload.

| Runner             | Process-culture exercise | Common gates                                                                                                                                                                   |
| ------------------ | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `windows-2022` x64 | `en-GB`                  | locked build, WebView2 detection, path/permission preflight, NSIS build and inspection, install, authenticated smoke, uninstall, residue, reinstall, cleanup, signing verifier |
| `windows-2025` x64 | `tr-TR`                  | same gates, independently rebuilt on the second runner generation                                                                                                              |

Each job exercises a source checkout and QA data root containing spaces and Unicode, verifies locale-invariant version/JSON handling, detects the installed WebView2 version, builds the packaged local core and current-user NSIS installer, and runs the authentic installed lifecycle. The installed application must demonstrate authenticated loopback readiness, isolated writable paths, owned-process cleanup, no machine-wide writes, and clean uninstall/reinstall behaviour. The concise job summary records the exact commit, runner image version, OS version, WebView2 version, installer filename/hash/size, signature-verifier states, and pass/fail result. Raw logs, screenshots, build trees, installers, and reports remain on the disposable runner and are not uploaded.

## Interpretation and limitations

GitHub-hosted Windows accounts are administrators with UAC disabled. The automated evidence proves `asInvoker` and current-user configuration plus absence of machine writes; it does not truthfully reproduce a locked-down non-administrator account. A real standard-user profile remains a manual/unverified dimension.

The matrix also does not establish behaviour under enterprise application-control policy, third-party antivirus, offline WebView2 installation, every system locale, DPI/scaling combinations, unusual GPU/hardware, or every Windows update level. A missing WebView2 Runtime fails the preflight with an actionable prerequisite message. These unverified dimensions must remain limitations in release notes rather than inferred passes.

## Release gate

Run the compatibility workflow only for a reviewed `main` commit and review both job summaries. Both jobs must pass before closing the release compatibility issue. Final Release QA remains a separate single-run gate for the exact release candidate SHA and is not replaced by this matrix.
