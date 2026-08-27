import { createContext, useContext } from "react";
import type { IdeContextMeta, WorkspaceMentionItem } from "./bridge";
import type { CopilotServiceState } from "./copilot-service-addon";
import type { ChecklistSnapshot } from "./checklist-reducer";
import type { MonitoredTask } from "./task-monitor";

export interface ShinyCommand { name: string; description?: string; prompt: string; category?: string; source?: string; kind?: string; argumentHint?: string; }
export interface ShinyToolItem { name: string; description?: string; }
export interface ShinyActionItem { section?: string; id: string; command?: string; label?: string; description?: string; }
export interface PermissionModeOption {
  value: string;
  label: string;
  description?: string;
  disabled?: boolean;
}

export type AssistantTextSize = "small" | "compact" | "medium";

/** Canonicalize persisted/server values while preserving the old medium=Default contract. */
export const normalizeAssistantTextSize = (value: unknown): AssistantTextSize | undefined => {
  if (value === "large") return "medium";
  return value === "small" || value === "compact" || value === "medium"
    ? value
    : undefined;
};
export interface PermissionModeState {
  value: string;
  options: PermissionModeOption[];
  pending: boolean;
  error: string | null;
  setValue: (value: string) => void;
}
export interface ThinkingState {
  value: string;
  options: PermissionModeOption[];
  setValue: (value: string) => void;
}
export interface ModelState {
  value: string;
  options: PermissionModeOption[];
  pending: boolean;
  requested: string | null;
  error: string | null;
  setValue: (value: string) => void;
  pickerOpen: boolean;
  setPickerOpen: (open: boolean) => void;
}
export interface WorkspaceMentionState {
  enabled: boolean;
  query: string;
  items: WorkspaceMentionItem[];
  loading: boolean;
}

export interface ShinyConfigCtx {
  tools: ShinyToolItem[];
  commands: ShinyCommand[];
  actionItems: ShinyActionItem[];
  showTimestamps: boolean;
  /** Plan 81: opt-in multi-project Claude Workspace navigation. */
  workspaceMode?: boolean;
  /** Session-local project registry order; independent from Favorites. */
  workspaceProjectOrder?: string[];
  /** Create a blank thread atomically bound to one Workspace project. */
  newThreadInProject?: (project: string) => void;
  onEnqueue: (text: string) => void;
  onRename: (threadId: string, title: string) => void;
  onInvokeAction: (item: ShinyActionItem) => void;
  onOpenFile?: (path: string, line?: number) => void;
  /** Increments whenever runtime accepts a new ordinary user submission. */
  submissionRevision?: number;
  onRunInConsole?: (code: string) => void;
  blockingAction?: {
    kind: "compact";
    phase: "starting" | "compacting";
    startedAt: number;
    message?: string;
  };
  permissionMode?: PermissionModeState;
  thinking?: ThinkingState;
  model?: ModelState;
  ideContext?: IdeContextMeta;
  selectionVisible: boolean;
  setSelectionVisible: (visible: boolean) => void;
  refreshIdeContext: () => void;
  workspaceMentions: WorkspaceMentionState;
  searchWorkspace: (query: string) => void;
  readingHistory?: boolean;
  historyHasMore?: boolean;
  loadingOlder?: boolean;
  loadOlderHistory?: () => void;
  // ── ClaudeAgentSDK 能力对齐 ──
  usage?: { costUsd?: number; tokens?: number; contextTokens?: number; turns?: number; durationMs?: number; model?: string; contextWindow?: number };
  /** Plan 36: per-thread agent state pushed from R via on_state(). */
  agentState?: unknown;
  /** Plan 34: enable KaTeX math rendering (opt-in). */
  latex?: boolean;
  /** Token-usage display (Plan 33): opt-in via assistantUIServer(show_usage=). */
  showUsage?: boolean;
  contextWindow?: number;
  usageStyle?: "ring" | "bar" | "text";
  tasks?: MonitoredTask[];
  recentTasks?: MonitoredTask[];
  checklist?: ChecklistSnapshot & { threadId: string };
  dismissChecklist?: (threadId: string, revision: string) => void;
  rateLimit?: { status?: string; resetsAt?: string; utilization?: number; type?: string } | null;
  statusText?: string | null;
  serviceState?: CopilotServiceState;
  pendingServiceSubmissions?: number;
  retryService?: () => void;
  cancelPendingServiceSubmissions?: () => void;
  warming?: boolean;
  warmingResuming?: boolean;
  runPhase?: "queued" | "connecting" | "running" | "complete" | "error" | "cancelled";
  runStage?: "submitting" | "model-switch" | "cold-connect" | "consumer-acquire" | "sending" | "awaiting-model" | "streaming" | "finalizing";
  runQueuePosition?: number;
  cancelRun?: () => void;
  /** Cold-start indicator text (English default "Starting…"); backend-specific override. */
  warmingLabel?: string;
  /** Empty-state welcome greeting (default "How can I help you today?"). */
  welcomeMessage?: string;
  stopTask?: (taskId: string) => void;
  forkThread?: () => void;
  /** 侧栏折叠且展开按钮浮在主面板左上角时为真 → 顶部"当前提问"框需左侧留白避让按钮 */
  sidebarCollapsed?: boolean;
  // ── 工作目录选择器（addin）──
  workingDir?: string;
  recentDirs?: string[];
  nativePicker?: boolean;
  pickWorkingDir?: () => void;
  setWorkingDir?: (path: string) => void;
  projects?: string[];
  saveProject?: () => void;
  removeProject?: (path: string) => void;
  filesPaneFollow?: boolean;
  setFilesPaneFollow?: (value: boolean) => void;
  autoRunEnabled?: boolean;
  setAutoRunEnabled?: (value: boolean) => void;
  /** Plan 45: persisted default permission mode for NEW conversations (addin). */
  defaultPermissionMode?: string;
  setDefaultPermissionMode?: (value: string) => void;
  /** Plan 45: which risky modes appear in the mode selector (hide Bypass/YOLO). */
  modeVisibility?: { showBypass: boolean; showYolo: boolean };
  setModeVisibility?: (value: { showBypass: boolean; showYolo: boolean }) => void;
  /** Plan 45: composer height preset — "comfortable" (default) | "compact" (flat, ~shinychat). */
  composerDensity?: "comfortable" | "compact";
  setComposerDensity?: (value: "comfortable" | "compact") => void;
  /** Plan 87: assistant response text size; medium preserves the existing 16px default. */
  assistantTextSize?: AssistantTextSize;
  setAssistantTextSize?: (value: AssistantTextSize) => void;
  /** Plan 45: whether the run_r MCP tool is loaded (addin; requires reconnect to apply). */
  runREnabled?: boolean;
  setRunREnabled?: (value: boolean) => void;
  autoStartCopilotApi?: boolean;
  setAutoStartCopilotApi?: (value: boolean) => void;
  /** CSS length capping chat content width; undefined = full width (default). */
  threadMaxWidth?: string;
}

export const ShinyConfigContext = createContext<ShinyConfigCtx>({
  tools: [],
  commands: [],
  actionItems: [],
  showTimestamps: false,
  onEnqueue: () => {},
  onRename: () => {},
  onInvokeAction: () => {},
  selectionVisible: true,
  setSelectionVisible: () => {},
  refreshIdeContext: () => {},
  workspaceMentions: { enabled: false, query: "", items: [], loading: false },
  searchWorkspace: () => {},
  readingHistory: false,
  historyHasMore: false,
  loadingOlder: false,
  loadOlderHistory: () => {},
});

export const useShinyConfig = () => useContext(ShinyConfigContext);
