# Compatibility notes

These observations describe the macOS Codex desktop interfaces the bar currently uses. They are implementation notes, not a public API promise.

## Codex's `/model` menu

In Codex desktop 26.917, Control+Shift+M opens the composer's `/model` menu without changing the draft. Number keys choose the first three recent configurations while the menu's search is empty. To find another model, the bar types the model id into the focused composer, waits until the menu exposes exactly one matching entry, and presses Return. The menu consumes Return and clears its search when selection succeeds. Accessibility `AXPress` and process-targeted clicks did not reliably choose menu entries in this version.

Escape closes an open menu but leaves typed search text in the composer. The bar removes its own search with Backspace only when the composer differs from its earlier value by exactly those characters. Synthetic keys stop when the user has typed recently; this avoids interleaving with live input. `ComposerText` tests cover the cleanup rule.

## Selecting the right task

Codex can show more than one composer. A model-button title alone cannot identify the task receiving keyboard input. The bar prefers the composer whose message box has keyboard focus and rechecks that focus as Codex moves between tasks. The current-model highlight follows that composer.

A newly opened extra Codex window was not a reliable live-test target in the observed desktop build: its web Accessibility tree could remain incomplete, and a task deep link opened the primary window. Live tests should identify the exact open task and verify the resulting model while preserving any in-progress draft.

## Reasoning effort

Codex desktop 26.917 exposes each model's `supportedReasoningEfforts` and `defaultReasoningEffort` through `model/list`; its on-disk cache uses `supported_reasoning_levels` and `default_reasoning_level`. The composer's model button title includes the current effort (for example, `Opus 5.5 Extra High`). Match the model name first, then parse the remaining effort label; a missing label is unknown, not proof of the model's default.

The installed Codex renderer has `composer.increaseReasoningEffort` and `composer.decreaseReasoningEffort` commands. User-assigned keys live in `~/.codex/keybindings.json`; do not assume a particular shortcut is available. The bar reads compatible bindings, sends them only to Codex's process, and checks the model button after each step. A model can expose different levels than another model, so the slider's tick count follows the current model's catalogue entry.

The bar's natural width can change even with a fixed slider width: the reasoning label varies between short and long levels, and a selected model button changes from regular to semibold text. Reserve the longest reasoning label width and each model button's widest font state. For a ticked `NSSlider`, set continuous updates for the preview label, then commit once when pointer tracking ends; committing on every drag event would send repeated shortcuts to Codex.
