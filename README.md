# Treki

A menu bar agent for macOS: press TAB to capture the focused field's text, or double-click the Treki icon to expand whatever you're typing via an LLM and write the expanded version back into the field.

## Usage

1. **First run:** `./build_app.sh && open build/Treki.app`. Grant Accessibility (System Settings > Privacy & Security > Accessibility) — it's granted once and survives rebuilds thanks to stable code signing.
2. **Configure the LLM:** open the popover (click the wand icon) > Settings…, pick a provider (Anthropic or any OpenAI-compatible endpoint), paste your API key (stored in Keychain), hit Save, then Test connection.
3. **Enhance while typing:** put the cursor in any text field, keep typing, then **double-click the Treki menu bar icon**. The focused field's text is replaced with the LLM's expanded version. If the app can't write back (e.g. Terminal), the result is copied to your clipboard instead.
4. **Capture:** press TAB in a focused field to log its contents to the popover (tracking toggle + swallow option in Settings).

## Architecture

- `KeyboardMonitor.swift` — global keyboard event tap (`CGEvent` at `.cgSessionEventTap` level). Sees TAB presses even when Treki isn't the active app.
- `AccessibilityService.swift` — finds the focused app/window/element (`AXUIElement`), detects editable text inputs (TextField, TextArea, ComboBox), reads `AXValue`, and replaces text (`replaceText`). Walks up to the nearest editable ancestor for web content.
- `LLMClient.swift` — async client for Anthropic's Messages API and any OpenAI-compatible `/chat/completions` endpoint (OpenAI, OpenRouter, Ollama, LM Studio).
- `KeychainStore.swift` — API key storage (generic password, service `com.treki.app`).
- `StatusItemController.swift` — menu bar item: single click opens the popover, double-click runs the enhance flow.
- `AppDelegate.swift` — wires the tap to capture logic; auto-(re)starts the tap once Accessibility is granted.
- `AppState.swift` — shared state: trust, tracking, captures, LLM config, enhance status.
- `TrekiApp.swift` / `TrekiMenuView.swift` / `SettingsView.swift` — agent app (LSUIElement, no Dock icon) UI.
- `DebugLogger.swift` — writes diagnostics to `~/Library/Logs/Treki.log`.

## Build & run

```bash
./build_app.sh        # builds release, signs with your Apple Development identity
open build/Treki.app
```

The build script signs with an existing Apple Development certificate if one is installed, otherwise creates a one-time self-signed "Treki Dev" identity. The Desktop is iCloud-synced, so the bundle is assembled and signed in a temp directory (iCloud's xattrs break codesign) and copied into `build/`.

## Notes

- LLM write-back uses `AXValue`; apps that don't expose it fall back to the clipboard.
- Some apps (Terminal, Xcode) expose text differently; capture may be empty there.