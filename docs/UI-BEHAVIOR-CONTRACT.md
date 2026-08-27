# UI behavior contract

This file records user-visible behavior that fixes and refactors must preserve. Tests should map to these rules rather than replacing one interaction with another.

## Streaming viewport

1. The existing down-arrow button is the single manual control for returning to the latest content. Do not add a duplicate “new response” control.
2. Submitting a new message scrolls to that new turn and enables follow mode, even if the user was previously reading an older turn.
3. If the viewport was already following the bottom, every streamed text/tool/status update remains visible as content grows. Layout growth alone must not disable follow mode.
4. If the user deliberately scrolls upward while a response is streaming, preserve that reading position and do not pull the viewport back down.
5. Clicking the existing down arrow or manually returning to the bottom re-enables follow mode.

## Claude checklist

1. Completed items display a `✓` and struck-through text. Status matching is trimmed and case-insensitive.
2. The `×` close button is available for active and completed checklists.
3. Closing dismisses the exact checklist revision. A genuine later task revision may appear again.
4. Collapse/expand and `+N more` behavior remain available; a status update must not reset the user's collapse choice.

## Agent output and activity

1. Parented subagent text/thinking is not promoted into the top-level assistant response.
2. Parallel Agent cards and their nested tool calls remain visible and independently settled.
3. The top-level final summary appears after the Agent cards without interleaved subagent tokens. A complete non-parented top-level `AssistantMessage` is delivered when received rather than held for a later terminal `ResultMessage`.
4. Agent tool results remain completion-granularity SDK data: do not fake token streaming or promote parented child output to make them appear incremental.
5. Existing running labels, spinner/shimmer, and elapsed timing remain visible while a tool, Agent, or Task is active, then freeze/clear on completion.

## Permission prompts

Manual mode displays approval only when Claude Code requests it; it is not an ask-every-tool mode. Strict mode or an explicit Claude permission `ask` rule is the deterministic approval-card test path.

## Assistant status and message actions

1. `Thinking…`/`thinking_tokens` and `requesting` are transient foreground-run statuses. Done, error, and cancellation clear them, and a late event cannot restore them after the run ends.
2. Other explicit backend statuses may remain visible outside a foreground run; do not globally suppress idle/proactive status reporting.
3. A tool-only assistant message renders its tool cards without the text-message footer, Copy/Reload/Export controls, or reserved footer spacing.
4. Assistant messages with non-whitespace text—including mixed text plus tools—retain the existing BranchPicker, Copy, Reload, Export, and timestamp footer behavior.
