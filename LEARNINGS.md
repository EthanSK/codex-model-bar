# Compatibility notes

These observations describe the macOS Codex desktop interfaces the bar currently uses. They are implementation notes, not a public API promise.

## Model catalogue after login

On 2026-09-25, the running bar saved a GPT-only `model/list` response while Codex was signed out or reconnecting. It hid Opus and Fable and showed GPT-5.6 models that the Claude bridge normally hides. After login, Codex's own `~/.codex/models_cache.json` listed Opus and Fable again and marked GPT-5.6 hidden; a fresh standalone `app-server` request also returned the Claude models. The bridge was healthy throughout inspection, so its startup was not the demonstrated cause.

Use the model cache written by the running Codex app as the bar's primary catalogue. Watch that file for changes so a sign-in refresh updates the buttons without restarting the bar. Keep the bar's last good list for startup and query a standalone `app-server` only when Codex's cache is unavailable. A regression test starts with an older GPT-only bar snapshot and verifies that the app cache restores Claude and hidden-model visibility.

## Codex's `/model` menu

In Codex desktop 26.917, Control+Shift+M opens the composer's `/model` menu without changing the draft. Number keys choose the first three recent configurations while the menu's search is empty. To find another model, the bar types the model id into the focused composer, waits until the menu exposes exactly one matching entry, and presses Return. The menu consumes Return and clears its search when selection succeeds. Accessibility `AXPress` and process-targeted clicks did not reliably choose menu entries in this version.

Escape closes an open menu but leaves typed search text in the composer. The bar removes its own search with Backspace only when the composer differs from its earlier value by exactly those characters. Synthetic keys stop when the user has typed recently; this avoids interleaving with live input. `ComposerText` tests cover the cleanup rule.

## Selecting the right task

Codex can show more than one composer. A model-button title alone cannot identify the task receiving keyboard input. The bar prefers the composer whose message box has keyboard focus and rechecks that focus as Codex moves between tasks. The current-model highlight follows that composer.

A newly opened extra Codex window was not a reliable live-test target in the observed desktop build: its web Accessibility tree could remain incomplete, and a task deep link opened the primary window. Live tests should identify the exact open task and verify the resulting model while preserving any in-progress draft.

The 1.2.3 regression fixtures cover main/side focus, a native picker temporarily holding focus, replaced model buttons, and detached composers whose AX parent and title remain readable. Resolve the focused composer first; retain a previous composer only while it remains in the live tree. An unrecognised focused text area must never redirect an action to a remembered input. Multiple unpaired inputs are ambiguous, not a reason to choose the first one. Check focus before each synthetic key, including cleanup, and confirm against the same composer's freshly located button.

An input with many attachment/control nodes can exceed the small subtree scan budget. A failing fixture with 220 neighbouring nodes demonstrated that returning unknown immediately misses a valid focused composer. Fall back to the bounded window scan, still requiring that the resulting composer contains the actual focus; do not substitute the previously focused side task.

Keep one watcher read in flight and discard results from an older focus/window revision. Slow AX walks must not accumulate behind a timer or overwrite a completed model change. Focus notifications request a fresh lookup; periodic polling still detects changes made through Codex's own picker. A successful switch returns both model and effort so the bar does not temporarily reset its slider to unknown. Retain hidden catalogue entries for recognising an existing task even though their buttons stay hidden.

## Reasoning effort

Codex desktop 26.917 exposes each model's `supportedReasoningEfforts` and `defaultReasoningEffort` through `model/list`; its on-disk cache uses `supported_reasoning_levels` and `default_reasoning_level`. The composer's model button title includes the current effort (for example, `Opus 5.5 Extra High`). Match the model name first, then parse the remaining effort label; a missing label is unknown, not proof of the model's default.

The installed Codex renderer has `composer.increaseReasoningEffort` and `composer.decreaseReasoningEffort` commands. User-assigned keys live in `~/.codex/keybindings.json`; do not assume a particular shortcut is available. The bar reads compatible bindings, sends them only to Codex's process, and checks the model button after each step. A model can expose different levels than another model, so the slider's tick count follows the current model's catalogue entry.

The bar's natural width can change even with a fixed slider width: the reasoning label varies between short and long levels, and a selected model button changes from regular to semibold text. Reserve the longest reasoning label width and each model button's widest font state. For a ticked `NSSlider`, set continuous updates for the preview label, then commit once when pointer tracking ends; committing on every drag event would send repeated shortcuts to Codex.

## Layout and pointer regression checks

On 2026-09-25, cycling an actual AppKit bar through natural, narrow, and restored widths with status messages reproduced model buttons collapsing to zero or two points. Width-only assertions had missed this. Compute the natural width from fixed control measurements, independent of the currently compressed layout. Lay out every model explicitly and use the reasoning area for status messages. The regression test checks every button's frame as well as the unchanged natural width.

In an isolated native window, the old slider's `super.mouseDown` returned after its initial action; a subsequent knob drag did not update the label or commit. Handle pointer down, drag, and up explicitly, map positions to the native tick geometry, preview while dragging, and commit on release. Cancel a drag when its model or focus context changes. Automated tests verify intermediate labels, one commit on release, and cancellation; manual native tests verify knob drags with different tick counts, external selection changes, narrow/restore layout and status recovery. The temporary window uses the production BarView; it is not the installed interface. Direct automation of Codex's own main/side windows was unavailable in that testing environment, so the focus-routing checks use tree fixtures rather than claiming a live end-to-end pass.
