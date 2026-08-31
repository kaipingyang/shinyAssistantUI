export type ChecklistStatus = "pending" | "in_progress" | "completed" | string;

export type ChecklistItem = {
  id: string;
  content: string;
  status: ChecklistStatus;
  activeForm?: string;
  description?: string;
};

export type ChecklistPreview = {
  visibleItems: ChecklistItem[];
  overflowCount: number;
};

type UnknownRecord = Record<string, unknown>;

const isRecord = (value: unknown): value is UnknownRecord =>
  value !== null && typeof value === "object" && !Array.isArray(value);

const nonEmptyString = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() ? value : undefined;

function normalizeChecklistStatus(value: unknown): ChecklistStatus {
  const status = nonEmptyString(value)?.trim().toLowerCase();
  if (!status) return "pending";
  if (["completed", "complete", "done"].includes(status)) return "completed";
  if (["in_progress", "in-progress", "in progress", "running"].includes(status)) {
    return "in_progress";
  }
  return status;
}

function parseRecord(value: unknown): UnknownRecord | undefined {
  if (isRecord(value)) return value;
  if (typeof value !== "string" || !value.trim()) return undefined;
  try {
    const parsed = JSON.parse(value);
    return isRecord(parsed) ? parsed : undefined;
  } catch {
    return undefined;
  }
}

function toolArgs(part: UnknownRecord): UnknownRecord | undefined {
  return parseRecord(part.args) ?? parseRecord(part.argsText);
}

function resultTaskId(result: unknown): string | undefined {
  const parsed = parseRecord(result);
  const nestedTask = isRecord(parsed?.task) ? parsed.task : undefined;
  const structured = nonEmptyString(
    parsed?.taskId ?? parsed?.task_id ?? parsed?.id ??
    nestedTask?.taskId ?? nestedTask?.task_id ?? nestedTask?.id,
  );
  if (structured) return structured;
  if (typeof result !== "string") return undefined;
  // Claude Code commonly returns prose rather than a structured object, e.g.
  // "Task #7 created successfully". The generic R bridge may also emit only
  // "Completed"; that case is adopted on the first matching TaskUpdate below.
  const match = result.match(/\btask(?:\s+id)?\s*[:#-]?\s*([A-Za-z0-9][\w.-]*)/i);
  return match?.[1];
}

function normalizeTodo(value: unknown, id: string): ChecklistItem | undefined {
  if (!isRecord(value)) return undefined;
  const content = nonEmptyString(value.content ?? value.subject);
  if (!content) return undefined;
  const activeForm = nonEmptyString(value.activeForm ?? value.active_form);
  const description = nonEmptyString(value.description);
  return {
    id: nonEmptyString(value.id ?? value.taskId ?? value.task_id) ?? id,
    content,
    status: normalizeChecklistStatus(value.status),
    ...(activeForm ? { activeForm } : {}),
    ...(description ? { description } : {}),
  };
}

/**
 * Rebuilds the current Claude checklist from ordered messages. TodoWrite is an
 * authoritative snapshot; TaskCreate/TaskUpdate incrementally modify the state.
 * Recomputing from history makes restore, paging, and thread isolation natural.
 */
export function reduceChecklistMessages(messages: readonly unknown[]): ChecklistItem[] {
  let items: ChecklistItem[] = [];
  // A real user turn creates a protocol-backed boundary. The first subsequent
  // TaskCreate starts a new current-task group; additional creates in that same
  // turn accumulate normally. TodoWrite remains an authoritative snapshot.
  let pendingTaskCreateBoundary = false;

  for (const message of messages) {
    if (isRealUserMessage(message)) pendingTaskCreateBoundary = true;
    if (!isRecord(message) || !Array.isArray(message.content)) continue;
    for (const rawPart of message.content) {
      if (!isRecord(rawPart) || rawPart.type !== "tool-call") continue;
      const toolName = nonEmptyString(rawPart.toolName ?? rawPart.tool_name);
      const args = toolArgs(rawPart);
      if (!toolName || !args) continue;
      const callId = nonEmptyString(rawPart.toolCallId ?? rawPart.tool_call_id) ?? "unknown";

      if (toolName === "TodoWrite") {
        if (!Array.isArray(args.todos)) continue;
        items = args.todos
          .map((todo, index) => normalizeTodo(todo, `${callId}:${index}`))
          .filter((item): item is ChecklistItem => Boolean(item));
        pendingTaskCreateBoundary = false;
        continue;
      }

      if (toolName === "TaskCreate") {
        const content = nonEmptyString(args.subject ?? args.content);
        if (!content) continue;
        if (pendingTaskCreateBoundary) {
          items = [];
          pendingTaskCreateBoundary = false;
        }
        const adoptedId = resultTaskId(rawPart.result);
        const id = adoptedId ?? `create:${callId}`;
        const activeForm = nonEmptyString(args.activeForm ?? args.active_form);
        const description = nonEmptyString(args.description);
        const created: ChecklistItem = {
          id,
          content,
          status: normalizeChecklistStatus(args.status),
          ...(activeForm ? { activeForm } : {}),
          ...(description ? { description } : {}),
        };
        const existing = items.findIndex((item) => item.id === id || item.id === `create:${callId}`);
        if (existing >= 0) items = items.map((item, index) => index === existing ? created : item);
        else items = [...items, created];
        continue;
      }

      if (toolName === "TaskUpdate") {
        const taskId = nonEmptyString(args.taskId ?? args.task_id ?? args.id);
        if (!taskId) continue;
        let index = items.findIndex((item) => item.id === taskId);
        if (index < 0) {
          // Historical bundles may contain only the generic "Completed" result.
          // Adoption is safe only when exactly one provisional creation exists;
          // with multiple candidates there is no protocol-backed association.
          const provisional = items
            .map((item, itemIndex) => ({ item, itemIndex }))
            .filter(({ item }) => item.id.startsWith("create:"));
          if (provisional.length === 1) index = provisional[0].itemIndex;
        }
        if (index < 0) continue;
        pendingTaskCreateBoundary = false;
        const current = items[index];
        const content = nonEmptyString(args.subject ?? args.content) ?? current.content;
        const status = normalizeChecklistStatus(args.status ?? current.status);
        const activeForm = nonEmptyString(args.activeForm ?? args.active_form) ?? current.activeForm;
        const description = nonEmptyString(args.description) ?? current.description;
        const updated: ChecklistItem = {
          ...current,
          id: taskId,
          content,
          status,
          ...(activeForm ? { activeForm } : {}),
          ...(description ? { description } : {}),
        };
        items = items.map((item, itemIndex) => itemIndex === index ? updated : item);
      }
    }
  }

  return items;
}

export function buildChecklistPreview(
  items: readonly ChecklistItem[],
  maxVisible = 5,
): ChecklistPreview {
  const limit = Math.max(0, Math.floor(maxVisible));
  return {
    visibleItems: items.slice(0, limit),
    overflowCount: Math.max(0, items.length - limit),
  };
}


export type ChecklistSnapshot = ChecklistPreview & {
  items: ChecklistItem[];
  allCompleted: boolean;
  revision: string;
  staleAfterUserTurn: boolean;
};

const CHECKLIST_TOOL_NAMES = new Set(["TodoWrite", "TaskCreate", "TaskUpdate"]);

function isRealUserMessage(message: unknown): boolean {
  if (!isRecord(message) || message.role !== "user") return false;
  const metadata = isRecord(message.metadata) ? message.metadata : undefined;
  const custom = isRecord(metadata?.custom) ? metadata.custom : undefined;
  return custom?.shinyAction !== true;
}

function hasChecklistTool(message: unknown): boolean {
  if (!isRecord(message) || !Array.isArray(message.content)) return false;
  return message.content.some((part) => {
    if (!isRecord(part) || part.type !== "tool-call") return false;
    const toolName = nonEmptyString(part.toolName ?? part.tool_name);
    return Boolean(toolName && CHECKLIST_TOOL_NAMES.has(toolName));
  });
}

function checklistRevision(items: readonly ChecklistItem[]): string {
  if (items.length === 0) return "";
  // Tuple encoding makes the signature deterministic and includes overflow
  // items, while remaining stable when older history pages are prepended.
  return JSON.stringify(items.map((item) => [
    item.id,
    item.content,
    item.status,
    item.activeForm ?? "",
    item.description ?? "",
  ]));
}

/**
 * Derives the UI lifecycle metadata for the current thread checklist.
 * Completed history becomes stale when a later real user turn starts; a new
 * checklist tool call changes the normalized revision and can show it again.
 */
export function buildChecklistSnapshot(
  messages: readonly unknown[],
  maxVisible = 5,
): ChecklistSnapshot {
  const items = reduceChecklistMessages(messages);
  let lastChecklistUpdateIndex = -1;
  let lastRealUserIndex = -1;
  messages.forEach((message, index) => {
    if (hasChecklistTool(message)) lastChecklistUpdateIndex = index;
    if (isRealUserMessage(message)) lastRealUserIndex = index;
  });
  const allCompleted = items.length > 0 && items.every(
    (item) => String(item.status).trim().toLowerCase() === "completed",
  );
  return {
    ...buildChecklistPreview(items, maxVisible),
    items,
    allCompleted,
    revision: checklistRevision(items),
    staleAfterUserTurn:
      allCompleted && lastRealUserIndex > lastChecklistUpdateIndex,
  };
}
