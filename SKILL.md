---
name: restore-computer-use
description: Restore Codex Computer Use plugin registration on Windows. Use when Codex settings shows the Computer Use plugin as unavailable, @Computer or @Computer Use is missing/unregistered, or Computer Use works through the bundled runtime but the settings UI says unavailable after switching providers, updates, restarts, or plugin sync issues.
---

# Restore Computer Use

## Overview

Restore the Windows Computer Use plugin registration without modifying Codex's installed app files. This fixes the common split-brain state where the bundled CUA runtime can operate apps, but the settings page says the Computer Use plugin is unavailable.

## Workflow

1. Confirm the symptom: Codex settings says the Computer Use plugin is unavailable, or `@Computer` is missing despite the app being the official Codex build.
2. Prefer a harmless runtime check if needed: ask Computer Use to open Notepad or list visible apps. If runtime works but settings says unavailable, treat it as a plugin registration/cache issue.
3. Run the bundled Computer Use repair script:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:CODEX_HOME\skills\restore-computer-use\scripts\restore-computer-use.ps1" -OpenSettings
```

If `CODEX_HOME` is unset, use:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\restore-computer-use\scripts\restore-computer-use.ps1" -OpenSettings
```

4. If the settings page shows repeated "plugin install failed" toasts, the Chrome row says "browser extension not connected", or an install button keeps reappearing after a Codex update, run the bundled install-cache repair script:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:CODEX_HOME\skills\restore-computer-use\scripts\repair-bundled-plugin-installs.ps1"
```

If `CODEX_HOME` is unset, use:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\restore-computer-use\scripts\repair-bundled-plugin-installs.ps1"
```

5. Restart Codex if the settings page does not refresh immediately.
6. Verify with `codex plugin list`: `computer-use@openai-bundled` must show `installed, enabled` with version `latest`. If it still says `not installed`, run the install-cache repair script again; do not replace `computer-use/latest` with a junction.
7. Re-test `@Computer` or open `codex://settings/computer-use`.

## What The Script Repairs

- Adds or refreshes `[marketplaces.openai-bundled]` in `config.toml`.
- Adds or refreshes `[plugins."computer-use@openai-bundled"] enabled = true`.
- Creates a user-cache junction for `computer-use/<version>` pointing to Codex's bundled plugin directory when the cache entry is missing.
- Writes a timestamped backup next to `config.toml` before changing it.

## What The Install-Cache Repair Script Repairs

- Adds or refreshes `[plugins."chrome@openai-bundled"] enabled = true`.
- Adds `latest` cache entries for bundled `computer-use`, `browser`, and `chrome`.
- Rebuilds `computer-use/latest` and `chrome/latest` as real writable copies instead of junctions, because the plugin installer does not count the `computer-use` junction as installed.
- Copies AppX "Application Protected" bundled files by reading and writing bytes, because normal `Copy-Item` can fail with "The specified file could not be encrypted."
- Repairs the local `@oai/sky` runtime export for `computer_use_client_base.js` when Computer Use fails with `Package subpath ... is not defined by "exports"` after a Codex update.
- Reinstalls the Chrome native messaging host manifest and HKCU registry entry with the current Codex runtime paths.
- Does not install the Chrome Web Store extension; if Chrome still says disconnected, ask the user to install or enable the Codex Chrome Extension in Chrome.

## Verification

- Run `codex plugin list` after repair.
- Treat `computer-use@openai-bundled installed, enabled latest` as the source of truth for the "Any app" settings row.
- If Computer Use is registered but app control fails with `Package subpath './dist/project/cua/sky_js/src/targets/windows/internal/computer_use_client_base.js' is not defined by "exports"`, run the install-cache repair script to patch the local `cua_node` runtime package metadata.
- Treat `chrome@openai-bundled installed, enabled latest` plus a passing native host check as the plugin-side Chrome fix.
- If Chrome still shows disconnected after that, the remaining issue is the Chrome Web Store extension in the selected Chrome profile, not the Codex plugin cache.

## Guardrails

- Do not edit random `false`/`true` fields or invent a `computer-use = true` switch.
- Do not write inside `C:\Program Files\WindowsApps`; use it only as the read-only source of the bundled plugin.
- If the script cannot find `plugins\openai-bundled\plugins\computer-use`, update/reinstall Codex before trying manual config edits.
- If `@Computer` cannot operate apps after registration is fixed, investigate runtime, Windows foreground visibility, app approvals, or provider/session state separately.
- If the Chrome extension itself is absent, do not fake Chrome profile state. Open the Codex Chrome Extension Web Store page only after the user agrees.
