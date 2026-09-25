# Codex Model Bar

**Models and reasoning, one click below Codex.** A 30-point macOS strip follows the active Codex desktop window. Its width fits the model buttons and reasoning control, and it highlights the model and effort used by the open task.

[Project page](https://ethansk.github.io/codex-model-bar/) · [Source](https://github.com/EthanSK/codex-model-bar) · [Claude in Codex](https://github.com/EthanSK/claude-in-codex)

The bar sits below the window when there is room, moves above it when there is not, and becomes a small overlay when the window fills the screen. It hides when Codex is in the background. The preview on the project page shows the layout; its buttons do not change a real Codex task.

## Install from source

You need **macOS 13 or later**, the **Codex desktop app**, and **Xcode Command Line Tools** (`xcode-select --install`). This repository currently provides source code, not a downloadable signed or notarized app.

```sh
git clone https://github.com/EthanSK/codex-model-bar.git
cd codex-model-bar
swift test
./scripts/build-app.sh
```

The script builds a release app for your Mac, signs it, installs it at `~/Applications/Codex Model Bar.app`, and opens it. On first launch, grant **Accessibility** access when macOS asks. If the prompt does not appear, use **System Settings → Privacy & Security → Accessibility** and enable Codex Model Bar. The app needs that access to find the open task's composer and operate Codex's model menu.

The script uses an available Apple Development identity for a stable signature. Without one, it uses an ad-hoc signature. An ad-hoc rebuild may need a fresh Accessibility grant. Set `CODEX_MODEL_BAR_SIGN_ID` to a specific signing identity if you have more than one. Use `./scripts/build-app.sh --no-install` to build `build/Codex Model Bar.app` without replacing the installed copy. `CODEX_MODEL_BAR_ARCH` can override the detected `arm64` or `x86_64` build architecture.

## Use

Click a model in the strip to change the **open Codex task**. The slider beside the models changes its reasoning level; each tick is one level supported by the current model. Its label previews the selected level while you drag, and the bar applies that level when you release. The strip keeps the same width as model selection and reasoning levels change. Right-click the strip to show or hide model buttons, refresh the list, turn **Open at login** on or off, or quit. Open at login is enabled on the first installed launch; you can disable it from the same menu. Hidden buttons are your local choice and do not remove models from Codex itself.

With a main task and side task open, the bar follows the input you have focused. It also follows changes made with Codex's own picker. If it cannot identify the active composer, it stops instead of choosing the first input in the window. Moving to another input during a reasoning drag cancels that drag. Status messages temporarily use the reasoning area, keeping every model button in place and preserving the strip's width.

Codex sometimes replaces a side task's input while applying a model or reasoning change. The bar follows a replacement only through a surviving container belonging to that composer. A new key or mouse press stops that confirmation, so moving to another task cannot confirm against the wrong input.

The reasoning slider uses Codex's **Increase reasoning effort** and **Decrease reasoning effort** commands. Assign both shortcuts in Codex's keyboard shortcut settings; the bar reads `~/.codex/keybindings.json` and only sends a shortcut that is actually configured. For example, assign `Ctrl+Command+Up` to increase and `Ctrl+Command+Down` to decrease. The bar confirms each step from Codex's composer before proceeding. If the shortcuts are missing or the composer does not report an effort, the slider cannot change it.

The buttons use model entries observed in Codex's shared cache. If you use [Claude in Codex](https://github.com/EthanSK/claude-in-codex), its Claude entries appear too. That cache can briefly omit models the desktop still offers, so refreshes preserve previously known entries and their button order. Updated names, reasoning levels and explicit hidden flags still apply. The saved list also survives a bar restart; hide an unwanted button from the right-click menu. Keeping a button does not guarantee account access: a switch still requires Codex's menu to offer the model. The bar can ask Codex's bundled `app-server` when the shared cache is unavailable, and you can refresh manually from the right-click menu.

To switch, the bar opens Codex's own `/model` menu with Control+Shift+M. It chooses a recent model with the menu's number shortcut. For another model, it searches by model id, checks that the menu found exactly that model, then presses Return to choose the result. It confirms the changed model in Codex's composer. It stops if you are typing and only removes search text it can prove it added, so it does not deliberately replace or send your draft.

## Limits and privacy

- The bar works with the macOS Codex desktop app. It uses the app's Accessibility tree, window list, bundled app-server and `/model` menu. Codex updates can change those interfaces and require a bar update.
- Accessibility access allows the app to inspect Codex's window and composer. The model switcher reads the draft before and after a search to preserve it. The reasoning control reads only the composer's model and effort title. It does not store chat text or include telemetry. It stores your hidden-button choices in macOS preferences and caches model names and supported effort levels locally in Application Support.
- Diagnostics stay on your Mac at `~/Library/Logs/Codex Model Bar/diagnostic.log`. They record app version, model/effort, opaque input and container identities, focus flags, lookup decisions, switch stages, timing and failure reasons. Confirmation records whether an input was replaced, whether it still belongs to the same composer, and whether draft cleanup was verified, observed as remaining, or unreadable/changed. They exclude draft text, chat content, task titles and individual keystrokes. The current log and one previous log are each limited to 2 MiB and readable only by your macOS user. Include the relevant failure entries when reporting a problem; nothing is uploaded automatically.
- A switch can stop when Codex is not ready, its menu has changed, or you are actively typing. The strip reports the failure. If it can read its exact search text remaining but cannot safely remove it, it tells you what remains. An unavailable or changed draft is recorded as unverified, not reported as proof of leftover text. A model change already confirmed in the correct composer remains successful when a later draft read is unverified.
- The source build is signed locally. It is not a notarized public binary release.

## Develop

`swift test` runs model parsing, title matching, draft-text, placement, composer-focus and stale-read tests, plus AppKit layout and slider-drag tests. `Sources/CodexModelBarCore` contains the pure logic. `Sources/CodexModelBar` contains the AppKit panel, Codex window tracking, model-menu interaction and reasoning shortcut control. `scripts/make-icon.swift` is the editable icon source. `LEARNINGS.md` records observed compatibility and testing lessons.

Contributions and issue reports are welcome. Please include the Codex desktop version and macOS version when reporting a model-switching problem, and remove personal task content from screenshots or logs.

MIT licensed. Codex Model Bar is an independent side project, not affiliated with or endorsed by OpenAI or Anthropic. Codex, ChatGPT and Claude are trademarks of their respective owners.
