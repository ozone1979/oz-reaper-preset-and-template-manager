# Oz Reaper Preset and Template Manager

A comprehensive REAPER preset and template management system with:

1. **Preset Library Management** — Browser-based interface for organizing, previewing, and managing REAPER presets.
2. **Preview Generation** — Automatic and manual preview generation for presets with rendering support.
3. **Native Instruments Komplete Standard (NKS) Sync** — Synchronize presets with NKS metadata for third-party plugins.
4. **Library Indexing** — Fast library scanning and index rebuilding with similarity analysis.
5. **Tagging System** — Organize presets with flexible tagging and metadata.
6. **Dockable Panel** — Integrated browser panel for quick access within REAPER.

## Files

- `index.xml` (ReaPack repository index)
- `RELEASE.md` (quick release checklist)
- `tools/generate-reapack-index.ps1` (regenerates `index.xml` from current files)
- `tools/publish-reapack-release.ps1` (one-command tag-based ReaPack release)
- `tools/sync-reaper-scripts.ps1` (one-command sync to local REAPER `Scripts/Oz Reaper Preset and Template Manager` test mirror)
- `Oz PTM - Register Actions.lua` (optional bulk action registrar)
- `Oz PTM - Cleanup Stale Actions.lua` (optional migration cleanup helper)
- `Oz PTM Core.lua` (compatibility loader that forwards to `libs/Oz PTM Core.lua`)
- `actions/*.lua` (canonical user-facing Action List scripts)
- `libs/Oz PTM Core.lua` (internal implementation)
- `libs/Oz PTM Config.lua` (configuration management)
- `libs/Oz PTM DB.lua` (database/library management)
- `libs/Oz PTM NKS.lua` (NKS metadata handling)
- `libs/Oz PTM Preview.lua` (preview generation)
- `libs/Oz PTM Scanner.lua` (library scanning)
- `libs/Oz PTM Similarity.lua` (similarity analysis)
- `libs/Oz PTM Tags.lua` (tag management)
- `libs/Oz PTM Theme.lua` (UI theming)
- `libs/UI/` (UI component library)

Hierarchy note:

- `actions/` is the authoritative location for user actions.
- `libs/` contains non-user-called implementation scripts and shared loaders.
- Top-level no longer duplicates the full action list.

## Setup in REAPER

1. Open **Actions** and import scripts from this folder.
	- Import scripts from `actions/`.
	- If you previously imported top-level actions from older versions, run/import `Oz PTM - Cleanup Stale Actions.lua` once.
	- Optional: run/import `Oz PTM - Register Actions.lua` to auto-register all `actions/Oz PTM - *.lua` scripts.
	- Do not import scripts from `libs/`.
2. Optionally bind shortcuts or toolbar buttons.
3. Run `Oz PTM - Rebuild Library Index.lua` to scan your preset directories.
4. Open the browser panel with `Oz PTM - Open Browser Panel.lua`.

## Local ReaPack sync/testing mirror

If you keep a local REAPER test mirror at `%APPDATA%\REAPER\Scripts\Oz Reaper Preset and Template Manager\Scripts`, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\sync-reaper-scripts.ps1
```

This copies all REAPER scripts to your test mirror for verification before publishing.

## Latest release

- `v0.1.0` — `https://github.com/YOUR_USERNAME/oz-reaper-preset-and-template-manager/releases/tag/v0.1.0`
