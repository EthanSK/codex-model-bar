# Compatibility notes

These observations describe the macOS Codex desktop interfaces the bar currently uses. They are implementation notes, not a public API promise.

## Codex's `/model` menu

In Codex desktop 26.917, Control+Shift+M opens the composer's `/model` menu without changing the draft. Number keys choose the first three recent configurations while the menu's search is empty. To find another model, the bar types the model id into the focused composer, waits until the menu exposes exactly one matching entry, and presses Return. The menu consumes Return and clears its search when selection succeeds. Accessibility `AXPress` and process-targeted clicks did not reliably choose menu entries in this version.

Escape closes an open menu but leaves typed search text in the composer. The bar removes its own search with Backspace only when the composer differs from its earlier value by exactly those characters. Synthetic keys stop when the user has typed recently; this avoids interleaving with live input. `ComposerText` tests cover the cleanup rule.

## Selecting the right task

Codex can show more than one composer. A model-button title alone cannot identify the task receiving keyboard input. The bar prefers the composer whose message box has keyboard focus and rechecks that focus as Codex moves between tasks. The current-model highlight follows that composer.

A newly opened extra Codex window was not a reliable live-test target in the observed desktop build: its web Accessibility tree could remain incomplete, and a task deep link opened the primary window. Live tests should identify the exact open task and verify the resulting model while preserving any in-progress draft.
