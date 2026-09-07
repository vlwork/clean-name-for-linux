# Changelog

Notable changes to this project are documented in this file.

The format is based on Keep a Changelog. This project is preparing a prerelease and does not yet declare a stable semantic-versioning compatibility policy.

## [6.0.0-preview.1] - Unreleased

### Added

- Windows Forms GUI with a read-only rename plan, summary counters, Browse and folder drag-and-drop input.
- Background scanning with progress indication, elapsed time, cancellation, and rescan support.
- Safe GUI Apply workflow with explicit confirmation and immediate plan revalidation before renaming.
- Embedded-core single-file Windows x64 EXE packaging with payload integrity verification.
- Pinned PS2EXE build pipeline producing an EXE and matching SHA-256 sidecar.
- Automated regression suite covering CLI behavior, GUI workflow, embedded/external core equivalence, and packaging failures.
- Performance benchmark for clean, dirty, Strict, mixed, and optional directory workloads.

### Changed

- Filename and directory component limits now use UTF-8 byte counts for the Linux/ext4 255-byte limit.
- Unicode handling preserves meaningful ZWJ/ZWNJ and combining marks while applying NFC and targeted cleanup.
- Strict sanitization uses more predictable replacement rules while preserving already-valid text such as original double hyphens.
- Conflict suffixes are generated with a dynamic UTF-8 byte budget and deterministic future-name reservation.
- Dry-run plans and Apply conflict handling now use the same snapshot-based planning rules.
- User-facing CLI, GUI, diagnostics, and build output are bilingual in English and Russian.

### Fixed

- Dotfile and Unicode-extension handling that could misclassify or over-sanitize the final extension.
- Strict extension-body replacement of contiguous sensitive metacharacters without globally collapsing valid hyphens.
- Conflict suffixes that could push file or directory names beyond the ext4 component limit.
- Directory names that could bypass UTF-8 byte limiting when no other cleanup was required.
- Dry-run conflict candidates that previously could differ from Apply for multiple future renames.
