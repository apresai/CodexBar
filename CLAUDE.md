# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is CodexBar

A macOS menu bar app that tracks AI service usage quotas across 20+ providers (Claude, Codex, Cursor, Gemini, Copilot, etc.). Built with SwiftUI + AppKit, Swift 6 strict concurrency, macOS 14+.

## Build & Run

```bash
./Scripts/compile_and_run.sh     # Full dev loop: kill → build → package → launch
./Scripts/package_app.sh         # Build and package only (no launch)
./Scripts/lint.sh lint           # SwiftLint + SwiftFormat check
./Scripts/lint.sh format         # Auto-format
swift test --no-parallel         # Run all tests (must be serial on macOS)
swift test --filter ClaudeOAuth  # Run tests matching a name
```

Line length: 120 warning, 250 error. Lint tools are pinned — run `./Scripts/install_lint_tools.sh` if missing.

## Module Structure

| Module | Purpose |
|--------|---------|
| `CodexBarCore` | Fetch + parse + shared logic. Provider descriptors, fetch strategies, keychain utilities, browser cookie import, config store, logging |
| `CodexBar` | State + UI. UsageStore, SettingsStore, StatusItemController, menus, provider settings UI |
| `CodexBarWidget` | WidgetKit extension (reads shared snapshot) |
| `CodexBarCLI` | Cross-platform CLI (`codexbar` command) |
| `CodexBarMacros` | SwiftSyntax macros for provider registration |
| `CodexBarClaudeWatchdog` | Helper process for stable Claude CLI PTY sessions |

## Data Flow

```
Background timer (1-30min) → UsageFetcher/provider strategies → UsageStore → menu/icon/widgets
Settings toggles → SettingsStore → UsageStore refresh cadence + feature flags
```

No dock icon (LSUIElement). A hidden 1×1 window keeps the SwiftUI lifecycle alive (`HiddenWindowView`).

## Provider System

Each provider has a **descriptor** (source of truth) in `Sources/CodexBarCore/Providers/<Name>/` and an **implementation** (UI hooks) in `Sources/CodexBar/Providers/<Name>/`.

Descriptors define: labels, URLs, default enablement, icon, capabilities, and a fetch pipeline of ordered strategies.

**Fetch strategy types**: `cli` (PTY), `web` (browser cookies), `oauth` (API), `api` (token), `local` (filesystem/LSP), `web-dashboard` (WebView scrape).

To add a provider: one folder, one descriptor + strategies, one implementation, icon SVG. Provider IDs are compile-time via `UsageProvider` enum. Macros (`@ProviderDescriptorRegistration`) auto-wire descriptors.

## Keychain Access (Critical Pattern)

CodexBar accesses the keychain for credentials, browser cookie decryption keys, and OAuth token caching. Follow these rules for all `SecItem*` calls:

- **CodexBar-owned items**: MUST use `KeychainDataProtection.apply(to:)` (`kSecUseDataProtectionKeychain`) — eliminates ACL prompts entirely
- **Data reads (`kSecReturnData`)**: MUST use `KeychainNoUIQuery.apply(to:)` unless explicitly user-initiated — prevents interactive prompts in background
- **Cross-app reads** (browser Safe Storage, Claude CLI keychain): cannot use data protection; MUST use `KeychainNoUIQuery` and record denials to the appropriate access gate (`BrowserCookieAccessGate` or `ClaudeOAuthKeychainAccessGate`)
- **Deletions**: when deleting legacy items alongside data protection items, verify data protection items survive (macOS Tahoe `SecItemDelete` may match both keychains)

Key files: `KeychainNoUIQuery.swift`, `KeychainDataProtection.swift`, `KeychainAccessPreflight.swift`, `KeychainCacheStore.swift`, `KeychainMigration.swift`. See `docs/KEYCHAIN_FIX.md` for full rules and log commands.

## Configuration

Provider settings live in `~/.codexbar/config.json` (0600 perms), not the keychain. Browser cookies are cached in keychain service `com.steipete.codexbar.cache`. The `CodexBarConfigStore` handles atomic reads/writes with validation.

## Logging

Central logger: `CodexBarLog.logger(LogCategories.<category>)`. 65+ kebab-case categories in `LogCategories.swift`. File logging to `~/Library/Logs/CodexBar/CodexBar.log` (opt-in via Debug menu).

View logs:
```bash
log stream --predicate 'subsystem == "com.steipete.codexbar" && category == "keychain-migration"' --style compact
```

## Testing

Tests use Swift Testing (`@Test`) and XCTest. Task-local overrides gate test infrastructure behind `#if DEBUG`:
- `KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting` — mock keychain checks
- `KeychainPromptHandler.withHandlerForTesting` — capture prompt events
- `KeychainCacheStore.setTestStoreForTesting` — in-memory test store
- Provider importers expose `*OverrideForTesting` hooks

Tests must run serially on macOS: `swift test --no-parallel`.

## Concurrency

Swift 6 strict concurrency. Use `Sendable` types, explicit `@MainActor` for UI, `nonisolated(unsafe)` only with locking. Task-local values (`@TaskLocal`) for test overrides. Background fetches use `Task.detached(priority: .utility)`.
