# Release checklist for 6.0.0-preview.1

Use this checklist immediately before creating the GitHub prerelease. Leave platform-specific items open until they have been tested on the named environment.

## Source and quality

- [x] Confirm branch `v6-development` and baseline code commit `21c4317` before release-preparation documentation changes.
- [ ] Record and verify the final release commit after the reviewed documentation is committed.
- [x] Confirm the main checkout was clean before release-preparation documentation changes.
- [x] Parse core, GUI, regression suite, benchmark, and build script with Windows PowerShell 5.1: zero errors.
- [x] Run the regression suite: 60 passed, 0 failed, exit code 0.
- [x] Repeat regression and build from a separate clean checkout of the release commit.
- [x] Review README commands, paths, switches, examples, links, and version references.
- [x] Update `CHANGELOG.md` with an Unreleased preview entry.
- [ ] Replace `Unreleased` with the actual release date when publishing.

## Build and artifact verification

- [x] Confirm PS2EXE 1.0.18 is installed and selected by the build.
- [x] Run `build\Build-Exe.ps1 -Clean` without `-SkipTests`.
- [x] Confirm successful build completion.
- [x] Confirm the PE machine is x64 (`0x8664`).
- [x] Confirm file/product version `6.0.0.0` and semantic release label `6.0.0-preview.1` are consistent.
- [x] Confirm `dist` contains only `Clean-File-Names.exe` and `Clean-File-Names.exe.sha256`.
- [x] Compare the sidecar SHA-256 with `Get-FileHash` for the same EXE.
- [x] Launch the EXE from a clean runtime directory containing no external core or config file.
- [x] Confirm the GUI opens without a console window and closes normally.
- [x] Confirm Microsoft Defender is enabled and its custom scan reports no detection for the candidate EXE.
- [ ] Perform an independent malware scan if required by release policy.

## GUI smoke matrix

- [ ] Windows 10 x64 at 100% display scaling.
- [ ] Windows 10 x64 at 125%, 150%, and 200% display scaling.
- [x] Windows 11 x64 at 100% display scaling.
- [ ] Windows 11 x64 at 125%, 150%, and 200% display scaling.
- [x] Browse, empty plan, dirty plan, confirmation No, confirmation Yes, Apply, Strict, directory rename, Cancel, and rescan.
- [ ] Repeat physical drag-and-drop manually in an interactive desktop session; automated regression coverage is present, but synthetic pointer automation was inconclusive in the release-preparation environment.
- [ ] Verify SmartScreen behavior on a downloaded artifact carrying Mark-of-the-Web.

## Repository and publication

- [ ] Confirm `git status --short` is empty before tagging.
- [x] Confirm release notes describe an unsigned Windows x64 preview and match README limitations.
- [x] Confirm no fabricated screenshot or placeholder image is included.
- [ ] Select and add an appropriate project `LICENSE`; none is currently present.
- [ ] Review GitHub About description, topics, and website field.
- [ ] Decide whether issue templates, contributing guidance, and a security policy are needed.
- [ ] Commit the reviewed documentation and any separately approved release changes.
- [ ] Create tag `v6.0.0-preview.1` from the approved commit.
- [ ] Create a GitHub prerelease, not a stable release.
- [ ] Upload only `Clean-File-Names.exe` and `Clean-File-Names.exe.sha256`.
- [ ] Download both published artifacts into a clean directory and verify the checksum again.
