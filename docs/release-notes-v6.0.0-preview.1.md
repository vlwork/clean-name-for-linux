# Clean Name for Linux 6.0.0-preview.1

`6.0.0-preview.1` is the first planned public preview of the v6 development line. It combines the PowerShell filename-cleaning core with a bilingual Windows GUI and a single-file x64 build.

## Highlights

- Review recursive rename plans in a responsive Windows Forms GUI before changing anything.
- Use Normal or Strict cleanup and optionally include nested directories.
- Keep Linux/ext4 filename components within 255 UTF-8 bytes without splitting Unicode text elements.
- Slash-like `U+29F8` (`⧸`) is normalized to ` - ` because real upload testing showed compatibility problems with this character.
- Resolve conflicts deterministically while preserving file extensions and complete ` (N)` suffixes where possible.
- Cancel a background scan, change settings, and rescan without accepting a partial plan.
- Require confirmation and revalidate the saved plan immediately before Apply.
- Run the GUI from one EXE with the PowerShell core embedded and integrity-checked.
- Verify the release artifact with the supplied SHA-256 sidecar.

## Download

The future GitHub prerelease should contain exactly:

```text
Clean-File-Names.exe
Clean-File-Names.exe.sha256
```

The release does not require a separate core script, config file, PDB, build directory, PS2EXE module, or PowerShell 7 installation beside the EXE.

## Requirements

- Windows 10 or Windows 11, x64.
- Permission to enumerate the selected directory and to rename its contents when Apply is used.
- The application does not request administrator elevation.

## Important

The preview EXE is unsigned. SmartScreen may warn for a newly downloaded file. Verify the EXE against the `.sha256` file shipped in the same release. A matching hash confirms artifact integrity; it is not a substitute for Authenticode signing.

## What preview users should test

- Scan representative media, archive, and multilingual filename collections without applying changes.
- Compare Normal and Strict plans, including apostrophes, brackets, ampersands, and extension punctuation.
- Exercise long ASCII, Cyrillic, emoji, and combining-character names near the 255-byte boundary.
- Test conflicts that require ` (1)`, multi-digit suffixes, and preserved extensions.
- Test nested directories with Rename directories enabled.
- Cancel a large scan, rescan, choose No at confirmation, and then complete a reviewed Apply.
- Check layout, text visibility, and controls at 125%, 150%, and 200% display scaling.
- Report the Windows version, display scaling, input names, expected result, and actual result with any issue.

## Known limitations

- Renaming is not transactional and has no journal or automatic rollback.
- External filesystem changes can still occur between final plan revalidation and `Rename-Item`.
- The selected root directory is not renamed.
- Conflict planning uses Windows case-insensitive ownership rules.
- Implemented Unicode cleanup does not guarantee every Unicode or filesystem edge case.
- Strict mode is not a guarantee of an unquoted shell-safe name.
- The EXE is Windows-only and unsigned.
- Independent PS2EXE builds are not expected to be byte-identical because compiler metadata includes varying timestamps and MVIDs.

Back up important data and review the complete dry-run plan before Apply.
