# Codex Model Bar

**Models, reasoning and speed, one click below Codex.** A 30-point macOS strip follows the active Codex desktop window. Its width fits the model buttons, reasoning control and three speed icons, and it highlights the model and effort used by the open task.

[Project page](https://ethansk.github.io/codex-model-bar/) · [Source](https://github.com/EthanSK/codex-model-bar) · [Claude in Codex](https://github.com/EthanSK/claude-in-codex)

The bar sits below the window when there is room, moves above it when there is not, and becomes a small overlay when the window fills the screen. It follows Codex's main task window rather than floating computer-use previews, and hides when Codex is in the background. The preview on the project page shows the layout; its buttons do not change a real Codex task.

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

Codex sometimes replaces a side task's input while applying a model or reasoning change. The bar follows a replacement only through a surviving container belonging to that composer. A new key or mouse press stops that confirmation, so moving to another task cannot confirm against the wrong input. If you click or type just after choosing a model, the bar still reads the original input once, so a switch Codex already applied is not reported as failed.

The reasoning slider uses Codex's **Increase reasoning effort** and **Decrease reasoning effort** commands. Assign both shortcuts in Codex's keyboard shortcut settings; the bar reads `~/.codex/keybindings.json` and only sends a shortcut that is actually configured. For example, assign `Ctrl+Command+Up` to increase and `Ctrl+Command+Down` to decrease. The bar confirms each step from Codex's composer before proceeding. If the shortcuts are missing or the composer does not report an effort, the slider cannot change it.

The buttons use model entries observed in Codex's shared cache. If you use [Claude in Codex](https://github.com/EthanSK/claude-in-codex), its Claude entries appear too. That cache can briefly omit models the desktop still offers, so refreshes preserve previously known entries and their button order. Updated names, reasoning levels and explicit hidden flags still apply. The saved list also survives a bar restart; hide an unwanted button from the right-click menu. Keeping a button does not guarantee account access: a switch still requires Codex's menu to offer the model. The bar can ask Codex's bundled `app-server` when the shared cache is unavailable, and you can refresh manually from the right-click menu.

The switcher uses Codex's inline `/model` menu, with 37.5 ms settling pauses. It recognises the typing menu when Codex renders it separately from the message box, restricted to the focused composer’s own web area. To switch, the bar opens the menu with Control+Command+M, searches by model id, checks that every result names the target model, then presses Return. It confirms the changed model in Codex's composer. If a floating typing panel takes keyboard focus during a switch, the bar restores Codex's focus and retries once only when the same composer and its unchanged draft can be verified. It stops if you type or click, and removes only search text it can prove it added. Live switches on the current desktop have succeeded, but a switch interrupted by a panel during search still needs a live check.

### Response speed

The three icons at the right are **Standard** (gauge), **Fast** (single bolt), and **Ultrafast** (double bolt). Hover for the name. Fast and Ultrafast put `/fast` or `/ultrafast` on the clipboard, paste with Command-V, then press Return using Agent Flow's foreground input sequence. They do not search, isolate or verify a command-menu entry, and do not backspace a rejected query. Like typing the command yourself, clicking an already active Fast or Ultrafast toggle returns to Standard. Codex handles the pasted command and Return, including unsupported commands or an existing draft. The bar reports the requested speed, not proof that Codex applied it; its icons are action buttons, not a cached speed indicator.

Fast and Ultrafast have no menu-settling pauses or readiness polling. The only event spacing is Agent Flow's 10 ms between Command-V key events and 30 ms between Return down/up. The command stays on the clipboard so a lagging app can read it; no timed clipboard restoration can replace it before paste consumption. Standard still reads the active slash toggle once because Codex has no `/standard` command, removes that discovery slash, then uses the same paste/Return route to turn the active tier off. If Standard is already active, it leaves it unchanged. Its discovery preserves the original composer and draft; this button can still wait for native menu readiness.

`codex-model-bar://speed-up` inserts **one `/ultrafast` command**; `codex-model-bar://speed-down` inserts **one `/fast` command**. These mouse actions directly invoke Codex's toggles: repeating the already active command returns to Standard. They do not discover or step through tiers. The handler never activates the bar or Codex; the Codex input must already have keyboard focus. Open the URLs with a nonactivating API.

Agentic Mouse sends `codex-model-bar://speed-cancel` on release to cancel queued ratchets. An already-started command may finish its paste and Return while Codex stays active. Requests queued for more than 0.5 seconds are discarded; after two seconds from arrival an active mouse request cannot paste or press Return. There are no command retries or confirmation queries. Rapid ratchets can therefore expire rather than replay later. Hardware input before admission cancels the action; a newer clipboard copy before V-down or a different foreground app before paste/Return stops delivery. These fixed URLs cannot supply text, change models or force Astra.

The physical paste/Return event sources, clipboard retention, cancellation, queued-release expiry, command descriptions, layout and button callbacks have automated coverage. The production double bolt was visually checked in an isolated native fixture, but that fixture lacked Accessibility permission for typing. Computer Use blocks direct Codex interaction in this environment, so the new installed paste sequence still needs a real desktop check. Native desktop updates can change the command descriptions or keyboard handling.

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

Agentic Mouse can request GPT-6 Astra with Ultrafast through the fixed local URL `codex-model-bar://astra-ultrafast`. The bar switches the focused composer using its existing model menu, then inspects `/ultrafast`. It selects the command only when Ultrafast is off and checks the command again to confirm it is on. Repeating the request keeps Ultrafast enabled. Unavailable commands, ambiguous entries, selected draft text or intervening input stop the action. This requires an eligible Codex account; it does not send a chat message. Live Codex UI acceptance of this new combined action remains unverified.
