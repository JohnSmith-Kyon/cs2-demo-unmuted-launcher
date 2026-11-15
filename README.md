# CS2 Demo Unmuted Launcher

A Windows launcher that creates a separate copy of a Counter-Strike 2 demo, attempts to remove recorded voice mute/listener restrictions, and starts playback through Steam.

[中文使用说明](README.zh-CN.md)

## Requirements

- Windows 10 or 11, with Steam and CS2 installed.
- Windows PowerShell 5.1 or PowerShell 7. The `.cmd` launchers prefer PowerShell 7 when available.
- A local `.dem` file, or a `.zip` containing exactly one `.dem`.
- Internet access for the first download of the pinned third-party patcher.
- Free disk space for processing; the original demo is never overwritten.

## Quick start

Download and extract this repository, then drag your `.dem` or `.zip` onto `Watch-CS2DemoUnmuted.cmd`. Alternatively, double-click the launcher and paste the file path.

If CS2 is closed, the launcher starts it through Steam. If CS2 is already running, the launcher copies an `exec cs2_demo_unmuted_<hash>.cfg` command to the clipboard for you to paste into the CS2 console. For the first playback test, fully exit CS2 before launching the processed demo.

The playback configuration enables recorded voice slots and disables TrueView with `cl_demo_predict 0`. It also sets the persistent `voice_modenable 1` setting; restore `voice_modenable 0` afterward if you normally keep voice disabled.

## PowerShell usage

```powershell
# Process and play a demo.
pwsh -NoProfile -File .\Watch-CS2DemoUnmuted.ps1 -DemoPath 'C:\path\match.dem'

# Process and verify without starting CS2.
pwsh -NoProfile -File .\Watch-CS2DemoUnmuted.ps1 -DemoPath 'C:\path\match.zip' -NoLaunch

# Rebuild the processed copy instead of reusing the verified cache.
pwsh -NoProfile -File .\Watch-CS2DemoUnmuted.ps1 -DemoPath 'C:\path\match.dem' -ForceReprocess

# Request a normal CS2 shutdown, then restart for playback.
pwsh -NoProfile -File .\Watch-CS2DemoUnmuted.ps1 -DemoPath 'C:\path\match.dem' -RestartIfRunning
```

Use `powershell.exe` instead of `pwsh` for Windows PowerShell 5.1. Finish your current match before using `-RestartIfRunning`; ordinary drag-and-drop use never closes the game.

## Generated files and cleanup

| Output | Location |
| --- | --- |
| Processed demos | `<CS2>\game\csgo\demos\CS2DemoUnmutedLauncher\` |
| Playback configurations | `<CS2>\game\csgo\cfg\cs2_demo_unmuted_<hash>.cfg` |
| Patcher cache, voice reports, integrity manifests | `%LOCALAPPDATA%\CS2DemoUnmutedLauncher\` |

Run `Clear-CS2LocalDemos.cmd` to review generated files and move them to the Recycle Bin after confirmation. Original demos and platform downloads are outside the default cleanup scope.

```powershell
# Inspect cleanup targets without deleting anything.
pwsh -NoProfile -File .\Clear-CS2LocalDemos.ps1 -ListOnly

# Preview the cleanup operations.
pwsh -NoProfile -File .\Clear-CS2LocalDemos.ps1 -WhatIf
```

See the [Chinese guide](README.zh-CN.md) for cache cleanup and permanent-deletion options.

## Compatibility and limitations

This is an experimental tool. It uses the pinned [OdyCSUnmuter v0.1.0-beta.1](https://github.com/OdyCS/OdyCSUnmuter/releases/tag/v0.1.0-beta.1) release and verifies both its archive and executable SHA-256 hashes before execution. The launcher repairs and validates PBDEMS2 footer offsets after rewriting, and checks cached outputs before reuse.

- The demo must already contain the target player's recorded voice. `Ready` confirms that some recorded voice exists, not that every player's speech is available or that playback has been verified. Check the speaker report for non-zero audio bytes for the target player.
- The patcher clears recorded mute state, expands listener masks, and remaps Steam identities. Names and voice remain identifiable; avatars/profile links may no longer match. This is not anonymization.
- The output may expose recorded team communications beyond the original listener restrictions. Do not publish private recordings or speaker reports without permission.
- CS2 updates and particular demo contents can break parsing or playback. This extraction does not upgrade the patcher's bundled `source2-demo 0.5.8` parser. Later parser releases contain compatibility fixes that are not included here.
- Local processing checks on 2026-11-15 passed for two demos dated 2026-10-31 and 2026-11-01, using PowerShell 5.1 and 7. These checks did not launch CS2 or verify audible playback and do not establish compatibility with every recent demo.
- The launcher supports demos up to approximately 4 GB and may need roughly three times the demo size in free space during initial processing.

When reporting a failure, include the final error lines, PowerShell version, CS2 version, and demo source/date. Share recordings and reports privately when they contain player information.

## Provenance and license

Extracted from the `cs2_demo_unmuted_launcher` directory of [JohnSmith-Kyon/game_scripts](https://github.com/JohnSmith-Kyon/game_scripts/tree/293b131/cs2_demo_unmuted_launcher). The launcher and cleanup scripts are unchanged by this extraction. The source repository remains available separately.

The launcher scripts retain the original repository's [Apache License 2.0](LICENSE). OdyCSUnmuter and its parser dependencies have their own licenses; see the [upstream notices](https://github.com/OdyCS/OdyCSUnmuter/blob/main/THIRD_PARTY_NOTICES.md). Third-party binaries, original demos, generated demos, voice reports, and local caches are not included in this repository.
