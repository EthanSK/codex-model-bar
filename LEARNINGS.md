# Compatibility notes

These observations describe the macOS Codex desktop interfaces the bar currently uses. They are implementation notes, not a public API promise.

## 1.2.13: the typing menu moved to a portal

A read-only capture after the user's 1.2.12 failure found the focused AXTextArea deep in the chat and an open `Recent models` section under a separate portal attached near the outer web area. Its section still contained the expected AXButton entries. The old lookup searched only four AXParent levels from the input, so it could never find this open menu and stopped before typing. More time did not fix the wrong search scope.

Resolve the inline menu from the live window child tree, restricted to the focused composer's nearest web area. Do not use a nested browser's menu, a detached input, or ambiguous separate menu containers. The original adjacent layout and new portal layout use the same section parsing; typing, Enter, delays and draft cleanup remain unchanged. Regression fixtures cover the captured deep input/portal arrangement, the old layout, browser isolation, duplicate menus and plain text without menu buttons. This fixes a captured discovery failure; automated and passive lookup checks still do not prove a full user-triggered switch.

## 1.2.12: the updated shortcut selects a different interface

The running 26.924.22138 bundle registers two distinct commands: `composer.openModelPicker` defaults to Control+Shift+M and opens the redesigned dropdown, while `composer.openRecentModels` defaults to Control+Command+M on macOS and calls the inline `model` slash-menu handler. The user's keybindings file has no override for either. The previous rollback retained the obsolete shortcut, so it still opened the wrong UI. Source evidence explains the observed menu mismatch; a live successful switch remains a separate check.

Use Control+Command+M for the original inline typing menu, then always type the model ID and press Enter after a unique matching result is visible. Ethan specifically requested the typing mechanism with delays; remove numbered recent-entry selection. Preserve 250 ms pauses after focus, menu opening and search completion, and recheck user input and the menu before Enter. Do not reintroduce the dropdown adapter. Historical descriptions of Control+Shift+M below apply to the earlier desktop version, not the currently installed app.

## 1.2.11: restore the verified inline baseline

Ethan rejected the unsuccessful recent picker experiments and requested the known working version plus a delay. Restore ModelSwitcher from 1.2.8 (da62431), remove the 1.2.9 dropdown adapter and its tests, and remove the 1.2.10 opening diagnostics and extended timeouts. The only switching changes against that baseline are 250 ms pauses after focus and after the inline menu appears, with user-input checks after each pause. Keep the independently verified catalogue, composer and main-window fixes from 1.2.8. Do not reintroduce the discarded dropdown approach without new evidence and Ethan's agreement (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).

Installed 1.2.8 logs show successful Astra, Sol and Opus switches on September 26, but also opening failures later; restoring it does not prove compatibility with the currently running desktop. The last 1.2.10 failure exposed an AXGroup focus chain and no AXMenu nodes after the timeout. The delay experiment did not resolve that attempt. The historical entries below document rejected attempts, not current switching behavior. All 53 remaining automated tests pass. Desktop switching still needs live confirmation.

## 1.2.10: pacing is an unverified mitigation

The user's next click after installing 1.2.9 still failed before either menu route was recognised. The installed attempt found the intended composer, sent the shortcut, and timed out; it never reached model selection. That proves the previous release did not resolve the reported case. It does not establish whether focus timing or menu discovery caused the failure. A passive follow-up capture observed ordinary navigation but no new toolbar attempt.

At the user's suggestion, allow 250 ms after focusing the composer and before selecting from a newly opened menu, then recheck focus/user activity and resolve live menu entries. Allow three seconds for the menu to appear, and give a dropdown selection 250 ms before closing it. Failed opening diagnostics now record only focus ancestry, menu identities, item counts and focus flags. These delays are a mitigation to test, not a proven root-cause fix; a successful automated suite or signed installation must not be reported as a successful desktop switch. Do not remove earlier catalogue, composer identity or draft protections based on this timing hypothesis. All 56 automated tests passed; the signed 1.2.10 app was installed and restarted. Live model switching remains unverified.

## 1.2.9: the shortcut can open two different model menus

On 2026-09-26, installed diagnostics showed the correct composer being located, followed by repeated “/model menu did not open” failures. Focus then belonged to an AXMenuItem and the modal menu temporarily hid the composer's model control, causing the following click to fail its initial lookup. The running app was `/Applications/ChatGPT.app` (26.924.22138), not the separate older `/Applications/Codex.app`; resolve the running executable before inspecting bundled renderer code. The running bundle contains both the inline Recent models/Matching models path and a dropdown handler for the same model-picker command. It is not evidence that the inline menu was removed.

After the shortcut, detect the focused dropdown as well as the inline menu. The dropdown's Select model item opens a list of model radio items; earlier layouts use a current-model submenu row. Match whole labels (including the UI's omitted GPT- prefix), ignore disabled entries and ambiguous matches, and confirm against the original composer after closing the menu. Keep dropdown actions bounded to its two selection steps and stop when the user interacts. Do not type search text or Return into a dropdown. Regression tests cover both menu layouts, stripped names, disabled and ambiguous matches. All 56 automated tests passed, and the signed installed 1.2.9 executable matches the built artifact. End-to-end desktop switching still requires a user click because Computer Use rejects control of Codex itself.

## 1.2.8: computer-use previews are not task windows

The user captured the bar underneath a floating computer-use preview on 2026-09-26. The tracker chose the frontmost layer-zero Codex window at least 480 by 360 points, allowing a large preview to displace the actual task window. Size and front-to-back order alone do not establish window ownership for the bar.

Resolve Codex's `AXMainWindow` on the existing AX queue, then match its top-left bounds to an on-screen CoreGraphics window (allowing two points for rounding). Keep the 30 Hz CoreGraphics follow for that window. When Accessibility is granted but the main window cannot be resolved, hide rather than falling back to the preview. Before the first Accessibility grant, preserve the existing window-list selection so the permission action remains reachable. Regression fixtures cover a frontmost preview, switching to a smaller main task window, missing/off-screen main windows, rounding and the initial permission flow. Anchor-change diagnostics record only the window ID and selection source. Installed 1.2.8 diagnostics matched the live main window, the installed executable matched the signed build, and Computer Use visually checked the bar. The preview ordering is covered by regression fixtures; a live floating-preview reproduction was not completed.

## Model catalogue after login

On 2026-09-25, the running bar saved a GPT-only `model/list` response while Codex was signed out or reconnecting. It hid Opus and Fable and showed GPT-5.6 models that the Claude bridge normally hides. After login, Codex's own `~/.codex/models_cache.json` listed Opus and Fable again and marked GPT-5.6 hidden; a fresh standalone `app-server` request also returned the Claude models. The bridge was healthy throughout inspection, so its startup was not the demonstrated cause.

Use Codex's shared model cache for catalogue observations, with a standalone `app-server` fallback when the cache is unavailable. Watch it for changes so sign-in updates appear without restarting the bar. Merge observations into the bar's saved list rather than replacing it (see the 1.2.6 finding below). A regression test starts with an older GPT-only bar snapshot and verifies that the shared cache restores Claude and explicit hidden-model visibility.

### 1.2.6: a shared-cache omission is not a removed model

On 2026-09-25 the user captured a bar showing only Opus and Fable while the Codex composer visibly used GPT-6 Sol High. At inspection, `models_cache.json` omitted all three GPT-6 models; a later rewrite restored them. The bar had persisted the smaller list over its own full snapshot. Because the same catalogue recognises model-button titles, the omission also made a focused Sol composer unrecognisable and produced `models=0` / `unpaired-focused-input` switch failures. The user's hidden choices still contained only GPT-5.5 and Luna. No evidence identified which process wrote the incomplete snapshot.

Retain previously observed entries and their order when a refresh omits them, including across bar restarts. Update metadata and explicit hidden flags for entries actually present, and keep user show/hide preferences separate. Serialise catalogue refreshes and atomic persistence. Log observed, retained and displayed model IDs so catalogue loss can be distinguished from an AX focus failure without recording chat content. A regression replays a full four-button catalogue followed by a Claude-only snapshot, verifies Sol title/effort recognition, and restarts the service while that partial snapshot remains. Another test verifies explicit hiding and reasoning metadata updates still apply.

The installed 1.2.6 runtime subsequently observed repeated real cache omissions of GPT-6 and logged those entries as retained, with the same four visible models before and after. A Computer Use inspection of the companion bar itself showed Astra, Sol, Opus and Fable with the reasoning slider. This verifies retention through the actual failure trigger without injecting a cache change into Codex or driving its protected UI.

## Codex's `/model` menu

In Codex desktop 26.917, Control+Shift+M opens the composer's `/model` menu without changing the draft. Number keys choose the first three recent configurations while the menu's search is empty. To find another model, the bar types the model id into the focused composer, waits until the menu exposes exactly one matching entry, and presses Return. The menu consumes Return and clears its search when selection succeeds. Accessibility `AXPress` and process-targeted clicks did not reliably choose menu entries in this version.

Escape closes an open menu but leaves typed search text in the composer. The bar removes its own search with Backspace only when the composer differs from its earlier value by exactly those characters. Synthetic keys stop when the user has typed recently; this avoids interleaving with live input. `ComposerText` tests cover the cleanup rule.

## Selecting the right task

Codex can show more than one composer. A model-button title alone cannot identify the task receiving keyboard input. The bar prefers the composer whose message box has keyboard focus and rechecks that focus as Codex moves between tasks. The current-model highlight follows that composer.

A newly opened extra Codex window was not a reliable live-test target in the observed desktop build: its web Accessibility tree could remain incomplete, and a task deep link opened the primary window. Live tests should identify the exact open task and verify the resulting model while preserving any in-progress draft.

The 1.2.3 regression fixtures cover main/side focus, a native picker temporarily holding focus, replaced model buttons, and detached composers whose AX parent and title remain readable. Resolve the focused composer first; retain a previous composer only while it remains in the live tree. An unrecognised focused text area must never redirect an action to a remembered input. Multiple unpaired inputs are ambiguous, not a reason to choose the first one. Check focus before each synthetic key, including cleanup, and confirm against the same composer's freshly located button.

An input with many attachment/control nodes can exceed a small subtree scan budget. A failing fixture with 220 neighbouring nodes demonstrated that returning unknown immediately misses a valid focused composer. The resolver now starts from a bounded live window scan rather than a small ancestor search; do not substitute the previously focused side task.

### 1.2.4: real Chromium focus differs from simple tree fixtures

Persistent diagnostics from the installed bar showed `AXParent`/`AXChildren` are not reciprocal across some flattened web groups. The 1.2.3 parent-membership check rejected live inputs and invalidated its own cache continuously. Discover composer/model pairs from the current window's children, then match the current input directly. Reuse a remembered input only if the live scan still finds that same paired input. This keeps the detached-node protection without requiring reciprocal parent links.

During a real side-task transition, the app reported an `AXGroup` as its focused element while one of two message inputs still reported `AXFocused=true`. Version 1.2.3 rejected that as ambiguous. When app focus is a container, accept exactly one focused input; if that input has no model control yet, stop rather than borrowing the main task's control. Keystroke focus checks use the same container/flag rule and reject any other focused text area.

The logs also recorded a newly focused side input before any model control appeared. A switch now gives that exact focused input up to one second to expose its model button. If the user moves focus during that wait, it does not retarget the other input. Fixtures cover flattened parents, container focus, conflicting flags and an unpaired focused side input. Live focus logging verifies these states during normal use; direct automation of Codex remains unavailable in this environment.

Keep the last paired input identity across a temporary render gap, separately from the current read result. The next lookup must rediscover that input in the live window before using it, and a different focused input still wins. Clear the remembered identity when the window changes.

### 1.2.5: side inputs can be replaced during confirmation

The installed 1.2.4 log captured a recent-model selection after which the original side input stopped exposing its role and left the live tree. The old confirmation checked focus on that retained object before performing another lookup, so it could not discover a replacement. The other composer already used the requested model; its title was not evidence that the side task switched. In a separate search attempt, the log confirmed Sol in the original focused composer, then reported failure because the later draft read differed. That input was replaced shortly afterward. These are distinct verification failures; neither log proves that the search text actually remained in the draft.

During confirmation, read the live tree first. Capture the input's live child-tree ancestors shared with its model control and containing no other input. A replacement can be matched only through a surviving exclusive ancestor, in the same active window, with focus, and without a new hardware key or mouse press. Do not infer continuity from matching models, window geometry, element order, or stale AX parent links. The same confirmation is used for reasoning steps. Allow a bounded five-second render gap and stop when the user interacts.

Treat an unreadable AX text value as unknown, not an empty draft. Only report leftover search when the readable value proves exactly that insertion. Model confirmation and draft cleanup are separate facts: a confirmed model does not become a failed switch merely because a later draft read is unknown or changed. Never backspace into a replacement input or after intervening user activity. Regression fixtures replay the side disappearance, reject the other already-matching composer, accept a replacement in a surviving scope, and reject stale/shared scopes. Result tests cover the confirmed-model/unverified-draft case.

Direct automation of Codex remains unavailable in this environment; fixtures and passive installed diagnostics are the available verification surfaces. Scope continuity must be recorded on a real replacement before claiming that path passed live.

### 1.2.7: user input after an applied switch is not a failed switch

Between 15:35 and 18:35 UTC on 2026-09-25, the installed 1.2.6 log recorded seven "Codex did not confirm the new model" failures, all stopped with `user-or-window-changed`. In six, the first confirmation read already showed the requested model on the original, unreplaced input in the same context. A hardware click or key press then arrived during the roughly one-second attempt, and the bar reported "Failed to switch" for a change Codex had applied. The seventh had lost its input (`input=none`) and remains a genuine unconfirmed attempt.

A model switch presses no keys after its final choice, so its confirmation may read the original input once after user input and accept that input's own button (focus not required). A replaced input still needs a surviving scope, focus and no user input. Reasoning steps keep the strict rule, because a later step would press another key and a click on another task can leave the same input showing a different chat. After user input the confirmation performs that single read and stops; it never keeps polling. `ModelSwitchResultTests` covers the original, replacement, reasoning and wrong-model cases.

### Local diagnostics

Keep persistent bounded diagnostics in `~/Library/Logs/Codex Model Bar/diagnostic.log`, with one rotated previous file. Record startup version/build, attempt IDs, phase/result, elapsed time, model/effort, opaque AX identities and focus-resolution decisions. Do not log drafts, conversations, task titles or individual user keystrokes. Tests cover restart persistence, single-line entries, private permissions and bounded rotation. Existing macOS unified logs were enough to distinguish a composer lookup failure from typing cancellation, but did not reveal why the input was rejected.

Keep one watcher read in flight and discard results from an older focus/window revision. Slow AX walks must not accumulate behind a timer or overwrite a completed model change. Focus notifications request a fresh lookup; periodic polling still detects changes made through Codex's own picker. A successful switch returns both model and effort so the bar does not temporarily reset its slider to unknown. Retain hidden catalogue entries for recognising an existing task even though their buttons stay hidden.

## Reasoning effort

Codex desktop 26.917 exposes each model's `supportedReasoningEfforts` and `defaultReasoningEffort` through `model/list`; its on-disk cache uses `supported_reasoning_levels` and `default_reasoning_level`. The composer's model button title includes the current effort (for example, `Opus 5.5 Extra High`). Match the model name first, then parse the remaining effort label; a missing label is unknown, not proof of the model's default.

The installed Codex renderer has `composer.increaseReasoningEffort` and `composer.decreaseReasoningEffort` commands. User-assigned keys live in `~/.codex/keybindings.json`; do not assume a particular shortcut is available. The bar reads compatible bindings, sends them only to Codex's process, and checks the model button after each step. A model can expose different levels than another model, so the slider's tick count follows the current model's catalogue entry.

The bar's natural width can change even with a fixed slider width: the reasoning label varies between short and long levels, and a selected model button changes from regular to semibold text. Reserve the longest reasoning label width and each model button's widest font state. For a ticked `NSSlider`, set continuous updates for the preview label, then commit once when pointer tracking ends; committing on every drag event would send repeated shortcuts to Codex.

## Layout and pointer regression checks

On 2026-09-25, cycling an actual AppKit bar through natural, narrow, and restored widths with status messages reproduced model buttons collapsing to zero or two points. Width-only assertions had missed this. Compute the natural width from fixed control measurements, independent of the currently compressed layout. Lay out every model explicitly and use the reasoning area for status messages. The regression test checks every button's frame as well as the unchanged natural width.

In an isolated native window, the old slider's `super.mouseDown` returned after its initial action; a subsequent knob drag did not update the label or commit. Handle pointer down, drag, and up explicitly, map positions to the native tick geometry, preview while dragging, and commit on release. Cancel a drag when its model or focus context changes. Automated tests verify intermediate labels, one commit on release, and cancellation; manual native tests verify knob drags with different tick counts, external selection changes, narrow/restore layout and status recovery. The temporary window uses the production BarView; it is not the installed interface. Direct automation of Codex's own main/side windows was unavailable in that testing environment, so the focus-routing checks use tree fixtures rather than claiming a live end-to-end pass.
