// useShinyRuntime — ExternalStoreRuntime + 多线程 + localStorage 持久化
// Module-level map: thread ID → formatted date string for sidebar display
export const sessionDates = new Map<string, string>();

import { useRef, useCallback, useState, useEffect, useMemo } from "react";
import {
  useExternalStoreRuntime, WebSpeechDictationAdapter, WebSpeechSynthesisAdapter,
  SimpleTextAttachmentAdapter, CompositeAttachmentAdapter,
} from "@assistant-ui/react";
import { ResizingImageAttachmentAdapter } from "./image-attachment-adapter";
import { FileAttachmentAdapter } from "./file-attachment-adapter";
import type {
  ThreadMessageLike,
  AppendMessage,
  ExternalStoreThreadData,
  StartRunConfig,
  FeedbackAdapter,
} from "@assistant-ui/core";
import { createShinyBridge } from "./bridge";
import type {
  ShinyBridge, SessionsPayload, ProactiveMessagesPayload, IdeContextMeta, WorkspaceMentionItem,
  AttachmentData, QuoteInfo, RunPhase, RunStage, AutoContinueKind,
} from "./bridge";
import {
  createCopilotServiceBridge,
  parseCopilotServiceAddon,
} from "./copilot-service-addon";
import type {
  CopilotServiceBridge,
  CopilotServiceState,
} from "./copilot-service-addon";
import { buildChecklistSnapshot } from "./checklist-reducer";
import {
  createTaskMonitorState,
  isTaskTerminalStatus,
  reduceTaskMonitorEvent,
  requestTaskStop,
  selectThreadTaskMonitor,
} from "./task-monitor";
import {
  normalizeAssistantTextSize,
  type AssistantTextSize,
  type PermissionModeOption,
  type PermissionModeState,
} from "./shiny-config-context";
import {
  storageKey, makeThreadId, markStaleToolCalls, stripAttachmentData,
  extractAttachments, expandSlashCommands, applyEdit, matchSlashAction,
  resolveToolFileReference,
} from "./helpers";
import { projectPartialWriteArgs } from "./tool-views/partial-tool-args";
import { projectLabel, sessionsToWorkspaceThreads } from "./workspace-threads";
import { createLazyToolResultClient, type LazyToolResultClient } from "./lazy-tool-result";

const RUN_SCOPED_TRANSIENT_STATUSES = new Set([
  "thinking_tokens",
  "requesting",
]);

// ── 持久化 key ──────────────────────────────────────────────────────────────

function loadThreads(inputId: string, enabled: boolean): ExternalStoreThreadData<"regular">[] {
  if (!enabled) return [];
  try {
    const raw = localStorage.getItem(storageKey(inputId, "threads"));
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

function saveThreads(inputId: string, enabled: boolean, threads: ExternalStoreThreadData<"regular">[]) {
  if (!enabled) return;
  try {
    localStorage.setItem(storageKey(inputId, "threads"), JSON.stringify(threads));
  } catch (e) {
    console.warn("[shinyAssistantUI] saveThreads failed:", e);
  }
}

function loadArchivedThreads(inputId: string, enabled: boolean): ExternalStoreThreadData<"archived">[] {
  if (!enabled) return [];
  try {
    const raw = localStorage.getItem(storageKey(inputId, "archived"));
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

function saveArchivedThreads(inputId: string, enabled: boolean, threads: ExternalStoreThreadData<"archived">[]) {
  if (!enabled) return;
  try {
    localStorage.setItem(storageKey(inputId, "archived"), JSON.stringify(threads));
  } catch (e) {
    console.warn("[shinyAssistantUI] saveArchivedThreads failed:", e);
  }
}

// 把所有未完成（result === undefined）的 tool-call part 标记为中断。
// markStaleToolCalls 已抽到 ./helpers，此处仅保留 localStorage 读写包装。

function loadMessages(inputId: string, enabled: boolean, threadId: string): ThreadMessageLike[] {
  if (!enabled) return [];
  try {
    const raw = localStorage.getItem(storageKey(inputId, `msgs:${threadId}`));
    if (!raw) return [];
    const msgs = JSON.parse(raw) as ThreadMessageLike[];
    // Any tool-call part without a result is stale (session ended mid-run) — mark as interrupted
    return markStaleToolCalls(msgs, "Session ended").messages;
  } catch {
    return [];
  }
}

// 落盘前剥离附件大体积 base64 data（stripAttachmentData 已抽到 ./helpers）。
function saveMessages(inputId: string, enabled: boolean, threadId: string, msgs: ThreadMessageLike[]) {
  if (!enabled) return;
  try {
    const slim = stripAttachmentData(msgs);
    localStorage.setItem(storageKey(inputId, `msgs:${threadId}`), JSON.stringify(slim));
  } catch (e) {
    // 配额超限等：不再完全静默，至少告警（数据仅当前会话内存可见，刷新丢失）
    console.warn(`[shinyAssistantUI] saveMessages failed (thread ${threadId}):`, e);
  }
}

function deleteMessages(inputId: string, enabled: boolean, threadId: string) {
  if (!enabled) return;
  try {
    localStorage.removeItem(storageKey(inputId, `msgs:${threadId}`));
  } catch {}
}

// makeThreadId / extractAttachments / expandSlashCommands 已抽到 ./helpers

// ── hook ────────────────────────────────────────────────────────────────────

type CommandDef = { name: string; description: string; prompt: string; category?: string };
type ActionItemDef = { id: string; command?: string; label?: string; section?: string; description?: string };
type CompactPhase = "starting" | "compacting" | "complete" | "error";
export type BlockingAction = {
  kind: "compact";
  phase: "starting" | "compacting";
  startedAt: number;
  message?: string;
};
type CompactActionProgress = {
  kind: "compact";
  phase: CompactPhase;
  startedAt: number;
  message?: string;
};

const COMPACT_CLIENT_TIMEOUT_MS = 185_000;

const isCompactPhase = (value: unknown): value is CompactPhase =>
  value === "starting" || value === "compacting" || value === "complete" || value === "error";
const AVAILABLE_PERMISSION_MODES = new Set([
  "default", "plan", "acceptEdits", "bypassPermissions", "askAll", "yolo",
]);

export function useShinyRuntime(inputId: string, config: Record<string, unknown>) {
  const usesRunStateProtocol = config?.run_state_protocol === 1;
  const configuredPersistence = config?.persistence;
  const persistence = configuredPersistence === "server" || configuredPersistence === "none"
    ? configuredPersistence
    : "client";
  const usesClientPersistence = persistence === "client";
  const workspaceMode = config?.workspace_mode === true;
  const initialSelectedProject = typeof config?.working_dir === "string" ? config.working_dir : "";
  const workingDirRef = useRef(initialSelectedProject);
  const threadProjectsRef = useRef(new Map<string, string>());
  const projectForThreadId = useCallback((threadId: string): string | undefined => {
    if (!workspaceMode) return undefined;
    return threadProjectsRef.current.get(threadId) || workingDirRef.current || undefined;
  }, [workspaceMode]);

  // 从 config 提取 commands（本地 skills），用于 /commandName → cmd.prompt 展开 + slash 菜单。
  // 用 state 而非 useMemo：切换工作目录时 R 会重载该项目的 skills 并经 :commands 热更新。
  const [commands, setCommands] = useState<CommandDef[]>(
    () => (config?.commands as CommandDef[] | undefined) ?? [],
  );
  const actionItems = useMemo(
    () => (config?.action_items as ActionItemDef[] | undefined) ?? [],
    [config],
  );
  const permissionCapability = useMemo(() => {
    const capabilities = config?.ui_capabilities as Record<string, unknown> | undefined;
    const raw = capabilities?.permission_mode as
      | { value?: unknown; options?: unknown }
      | undefined;
    if (typeof raw?.value !== "string" || !Array.isArray(raw.options)) return undefined;
    const options = raw.options.filter((option): option is PermissionModeOption => {
      if (!option || typeof option !== "object") return false;
      const candidate = option as Record<string, unknown>;
      return typeof candidate.value === "string" && typeof candidate.label === "string";
    });
    return { value: raw.value, options };
  }, [config]);
  // 思考强度能力（B3）：与 permission 同形状的 {value, options}。
  const thinkingCapability = useMemo(() => {
    const caps = config?.ui_capabilities as Record<string, unknown> | undefined;
    const raw = caps?.thinking as { value?: unknown; options?: unknown } | undefined;
    if (typeof raw?.value !== "string" || !Array.isArray(raw.options)) return undefined;
    const options = raw.options.filter((option): option is PermissionModeOption => {
      if (!option || typeof option !== "object") return false;
      const c = option as Record<string, unknown>;
      return typeof c.value === "string" && typeof c.label === "string";
    });
    return { value: raw.value, options };
  }, [config]);
  // 模型能力（#1 /model）：与 thinking 同形状 {value, options}。
  const modelCapability = useMemo(() => {
    const caps = config?.ui_capabilities as Record<string, unknown> | undefined;
    const raw = caps?.model as { value?: unknown; options?: unknown } | undefined;
    if (typeof raw?.value !== "string" || !Array.isArray(raw.options)) return undefined;
    const options = raw.options.filter((option): option is PermissionModeOption => {
      if (!option || typeof option !== "object") return false;
      const c = option as Record<string, unknown>;
      return typeof c.value === "string" && typeof c.label === "string";
    });
    return { value: raw.value, options };
  }, [config]);
  const capabilityContract = useMemo(() => {
    const caps = config?.ui_capabilities as Record<string, unknown> | undefined;
    if (caps?.contract_version !== 1) return { ide: false, workspace: false };
    const ide = caps.ide_context as Record<string, unknown> | undefined;
    const workspace = caps.workspace_mentions as Record<string, unknown> | undefined;
    return {
      ide: ide?.submit === true && ide?.preview === true,
      workspace: workspace?.search === true,
    };
  }, [config]);
  // 懒初始化：避免每次 render 都调用 createShinyBridge（会重复注册 Shiny handler
  // 覆盖旧的，但 useRef 还是返回第一个 bridge，导致 handler 和 callbacks 对应的闭包不一致）
  const bridge = useRef<ShinyBridge>(null!);
  if (!bridge.current) {
    bridge.current = createShinyBridge(inputId);
  }
  const lazyToolResults = useRef<LazyToolResultClient>(null!);
  if (!lazyToolResults.current) {
    lazyToolResults.current = createLazyToolResultClient(
      (request) => bridge.current.requestToolResultChunk(request),
    );
    bridge.current.onToolResultChunk((chunk) => lazyToolResults.current.accept(chunk));
  }
  const copilotServiceConfig = useMemo(() => parseCopilotServiceAddon(config), [config]);
  const copilotBridge = useRef<CopilotServiceBridge | null>(null);
  if (copilotServiceConfig && !copilotBridge.current) {
    copilotBridge.current = createCopilotServiceBridge(inputId);
  }

  type HistoryPageState = {
    reading: boolean;
    hasMore: boolean;
    cursor: string | number | null;
    loadingOlder: boolean;
  };
  const emptyHistoryPage: HistoryPageState = {
    reading: false, hasMore: false, cursor: null, loadingOlder: false,
  };
  const [historyPageStates, setHistoryPageStates] = useState<Record<string, HistoryPageState>>({});
  const historyPageStatesRef = useRef<Record<string, HistoryPageState>>({});
  const updateHistoryPage = useCallback((
    threadId: string,
    updater: (previous: HistoryPageState) => HistoryPageState,
  ) => {
    const next = updater(historyPageStatesRef.current[threadId] ?? emptyHistoryPage);
    historyPageStatesRef.current = { ...historyPageStatesRef.current, [threadId]: next };
    setHistoryPageStates(historyPageStatesRef.current);
  }, []);

  // 历史 session 的 lazy-load 状态。只有收到 :load-thread 才进入 loaded；
  // loading 用于阻止重复点击发起并发请求，超时后退回 unloaded 允许重试。
  const sessionLoadStates = useRef(new Map<string, "unloaded" | "loading" | "loaded">());
  const serverSessionIdsRef = useRef(new Set<string>());
  // Protect live in-memory turns from an older transcript snapshot.
  const activeRunsRef = useRef<Set<string>>(new Set());
  const deletedThreadIdsRef = useRef<Set<string>>(new Set());
  const activeTaskRunIdsRef = useRef<Record<string, string>>({});
  const completedRunIdsRef = useRef<Record<string, string>>({});
  const knownThreadIdsRef = useRef(new Set<string>());
  const proactiveRevisionsRef = useRef(new Map<string, number>());
  const proactiveBeforeSessionsRef = useRef(new Map<string, ProactiveMessagesPayload[]>());
  const proactiveAfterRunRef = useRef(new Map<string, ProactiveMessagesPayload>());
  const proactiveSkipNextHistoryRefreshRef = useRef(new Set<string>());
  const hasSessionsSnapshotRef = useRef(false);
  const runSeqRef = useRef<Record<string, number>>({});
  const historyRequestSeqRef = useRef(0);
  const historyReplaceRequestsRef = useRef(new Map<string, { requestId: string; runSeq: number }>());
  const historyOlderRequestsRef = useRef(new Map<string, string>());
  const historyRequiresRequestIdRef = useRef(new Set<string>());
  const sessionLoadRetryTimers = useRef(new Map<string, number>());
  const olderPageRetryTimers = useRef(new Map<string, number>());
  // Remove all request correlation before a thread disappears. Any response
  // carrying its old requestId will then be ignored by onLoadThread.
  const clearThreadHistoryTracking = useCallback((threadId: string) => {
    const retryTimer = sessionLoadRetryTimers.current.get(threadId);
    if (retryTimer !== undefined) window.clearTimeout(retryTimer);
    const olderTimer = olderPageRetryTimers.current.get(threadId);
    if (olderTimer !== undefined) window.clearTimeout(olderTimer);
    sessionLoadRetryTimers.current.delete(threadId);
    olderPageRetryTimers.current.delete(threadId);
    historyReplaceRequestsRef.current.delete(threadId);
    historyOlderRequestsRef.current.delete(threadId);
    historyRequiresRequestIdRef.current.add(threadId);
    sessionLoadStates.current.delete(threadId);
    serverSessionIdsRef.current.delete(threadId);
    if (threadId in historyPageStatesRef.current) {
      const next = { ...historyPageStatesRef.current };
      delete next[threadId];
      historyPageStatesRef.current = next;
      setHistoryPageStates(next);
    }
  }, []);
  const currentThreadIdRef = useRef<string>("");
  // 稳定 ref，供注册一次的 onSessions 回调读取当前 threadId（绕过 stale closure）
  // 本次 React 实例（页面加载后）新建的线程 ID 集合。
  // onSessions 到达时用 server 列表替换 localStorage 线程，但保留这些本地新建线程，
  // 避免把用户正在进行的对话丢掉。
  const thisSessionThreadIds = useRef(new Set<string>());
  const requestSessionLoad = useCallback((threadId: string, refresh = false) => {
    const state = sessionLoadStates.current.get(threadId);
    if (state === "loading") return;
    if (!refresh && state !== "unloaded") return;
    // A live run is newer than the transcript snapshot on disk. Never replace
    // its in-memory messages merely because the user switches back to it.
    if (refresh && activeRunsRef.current.has(threadId)) return;
    const olderTimer = olderPageRetryTimers.current.get(threadId);
    if (olderTimer !== undefined) window.clearTimeout(olderTimer);
    olderPageRetryTimers.current.delete(threadId);
    if (historyOlderRequestsRef.current.has(threadId)) {
      historyRequiresRequestIdRef.current.add(threadId);
    }
    historyOlderRequestsRef.current.delete(threadId);
    sessionLoadStates.current.set(threadId, "loading");
    const requestId = `history-${Date.now()}-${++historyRequestSeqRef.current}`;
    historyReplaceRequestsRef.current.set(threadId, {
      requestId, runSeq: runSeqRef.current[threadId] ?? 0,
    });
    updateHistoryPage(threadId, (previous) => ({
      ...previous, reading: true, hasMore: false, cursor: null, loadingOlder: false,
    }));
    bridge.current.sendLoadSession(threadId, threadId, requestId, projectForThreadId(threadId));
    const timer = window.setTimeout(() => {
      const pending = historyReplaceRequestsRef.current.get(threadId);
      if (pending?.requestId === requestId) {
        historyReplaceRequestsRef.current.delete(threadId);
        historyRequiresRequestIdRef.current.add(threadId);
        if (sessionLoadStates.current.get(threadId) === "loading") {
          sessionLoadStates.current.set(threadId, "unloaded");
          updateHistoryPage(threadId, (previous) => ({ ...previous, reading: false }));
        }
        sessionLoadRetryTimers.current.delete(threadId);
      }
    }, 15_000);
    sessionLoadRetryTimers.current.set(threadId, timer);
  }, [updateHistoryPage, projectForThreadId]);

  useEffect(() => () => {
    for (const timer of sessionLoadRetryTimers.current.values()) {
      window.clearTimeout(timer);
    }
    for (const timer of olderPageRetryTimers.current.values()) {
      window.clearTimeout(timer);
    }
    sessionLoadRetryTimers.current.clear();
    olderPageRetryTimers.current.clear();
    if (workspaceDebounceRef.current !== null) window.clearTimeout(workspaceDebounceRef.current);
  }, []);

  const [ideContext, setIdeContext] = useState<IdeContextMeta | undefined>(undefined);
  const [selectionVisible, setSelectionVisibleState] = useState(true);
  const [workspaceMentions, setWorkspaceMentions] = useState<{
    enabled: boolean; query: string; items: WorkspaceMentionItem[]; loading: boolean;
  }>({ enabled: capabilityContract.workspace, query: "", items: [], loading: false });
  const ideRequestSeq = useRef(0);
  // 工作目录选择器（addin）：初始值来自 config；切换后由 :working-dir 消息更新。
  const [workingDir, setWorkingDirState] = useState<string>(
    () => initialSelectedProject,
  );
  const [gitBranch, setGitBranch] = useState<string | undefined>(
    () => typeof config?.git_branch === "string" && config.git_branch.length > 0
      ? config.git_branch
      : undefined,
  );
  workingDirRef.current = workingDir;
  const [recentDirs, setRecentDirs] = useState<string[]>([]);
  const nativePicker = config?.native_picker === true;
  // Files 面板跟随开关（addin/RStudio）。undefined = 无此能力（不显示开关）。
  const [filesPaneFollow, setFilesPaneFollowState] = useState<boolean | undefined>(
    () => (typeof config?.files_pane_follow === "boolean" ? config.files_pane_follow : undefined),
  );
  const [autoRunEnabled, setAutoRunEnabledState] = useState<boolean | undefined>(
    () => (typeof config?.auto_run === "boolean" ? config.auto_run : undefined),
  );
  const [defaultPermissionMode, setDefaultPermissionModeState] = useState<string | undefined>(
    () => (typeof config?.default_permission_mode === "string" ? config.default_permission_mode : undefined),
  );
  const [modeVisibility, setModeVisibilityState] = useState<{ showBypass: boolean; showYolo: boolean } | undefined>(
    () => {
      const mv = config?.mode_visibility as { showBypass?: boolean; showYolo?: boolean } | undefined;
      return mv ? { showBypass: mv.showBypass !== false, showYolo: mv.showYolo !== false } : undefined;
    },
  );
  const [composerDensity, setComposerDensityState] = useState<"comfortable" | "compact" | undefined>(
    () => (config?.composer_density === "compact" || config?.composer_density === "comfortable"
      ? config.composer_density : undefined),
  );
  const [assistantTextSize, setAssistantTextSizeState] = useState<AssistantTextSize | undefined>(
    () => normalizeAssistantTextSize(config?.assistant_text_size),
  );
  const [runREnabled, setRunREnabledState] = useState<boolean | undefined>(
    () => (typeof config?.run_r_enabled === "boolean" ? config.run_r_enabled : undefined),
  );
  const [autoStartCopilotApi, setAutoStartCopilotApiState] = useState<boolean | undefined>(
    () => copilotServiceConfig?.state.autoStart,
  );
  const [serviceState, setServiceState] = useState<CopilotServiceState | undefined>(
    () => copilotServiceConfig?.state,
  );
  const serviceStateRef = useRef<CopilotServiceState | undefined>(serviceState);
  const [projects, setProjects] = useState<string[]>(
    () => (Array.isArray(config?.projects) ? (config.projects as string[]) : []),
  );
  const [workspaceProjectOrder, setWorkspaceProjectOrder] = useState<string[]>([]);
  const workspaceRequestSeq = useRef(0);
  const workspaceDebounceRef = useRef<number | null>(null);
  const latestIdeRequest = useRef<string | null>(null);
  const latestWorkspaceRequest = useRef<string | null>(null);
  const selectionVisibleRef = useRef(true);

  // 反馈适配器（稳定引用，通过 bridge 发送到 R 端）
  const feedbackAdapter = useRef<FeedbackAdapter>({
    submit: ({ message, type }) => {
      bridge.current.sendFeedback(message.id, type === "positive" ? "positive" : "negative");
    },
  });

  // 文件上传适配器（image + 纯文本，稳定引用）
  const attachmentAdapter = useRef<CompositeAttachmentAdapter>(null!);
  if (!attachmentAdapter.current) {
    attachmentAdapter.current = new CompositeAttachmentAdapter([
      new ResizingImageAttachmentAdapter(),
      new SimpleTextAttachmentAdapter(),
      new FileAttachmentAdapter(), // Plan 56: PDF(→document block) + Excel(→readxl)
    ]);
  }

  // 线程列表（持久化）
  const [threads, setThreads] = useState<ExternalStoreThreadData<"regular">[]>(() =>
    loadThreads(inputId, usesClientPersistence)
  );

  // 归档线程列表（持久化）
  const [archivedThreads, setArchivedThreads] = useState<ExternalStoreThreadData<"archived">[]>(() =>
    loadArchivedThreads(inputId, usesClientPersistence)
  );

  // Composer text belongs to the currently bound ExternalStoreRuntime. Keep an
  // instance-local draft per thread before that binding moves to another thread.
  // This is deliberately memory-only: restoring a page must never auto-revive or
  // submit stale text from a previous addin instance.
  type ComposerDraftRuntime = {
    thread: {
      composer: {
        getState: () => { text: string };
        setText: (text: string) => void;
      };
    };
  };
  const composerDraftsRef = useRef(new Map<string, string>());
  const runtimeRef = useRef<ComposerDraftRuntime | null>(null);

  // 当前 threadId
  const [currentThreadId, setCurrentThreadIdState] = useState<string>(() => {
    const saved = loadThreads(inputId, usesClientPersistence);
    if (saved.length > 0) return saved[0].id; // 来自 localStorage（上次运行），不追踪
    const id = makeThreadId();
    thisSessionThreadIds.current.add(id);       // 本次新建，追踪
    return id;
  });
  // 每次 render 更新 ref，让注册一次的回调（onSessions 等）始终读到最新值
  currentThreadIdRef.current = currentThreadId;
  selectionVisibleRef.current = selectionVisible;

  const rememberComposerDraft = useCallback((threadId: string) => {
    const text = runtimeRef.current?.thread.composer.getState().text ?? "";
    if (text.length > 0) composerDraftsRef.current.set(threadId, text);
    else composerDraftsRef.current.delete(threadId);
  }, []);

  const switchCurrentThread = useCallback((threadId: string, preserveCurrent = true) => {
    const previousThreadId = currentThreadIdRef.current;
    if (threadId === previousThreadId) return;
    if (preserveCurrent && previousThreadId) rememberComposerDraft(previousThreadId);
    setCurrentThreadIdState(threadId);
  }, [rememberComposerDraft]);

  const loadOlderHistory = useCallback(() => {
    const threadId = currentThreadIdRef.current;
    const page = historyPageStatesRef.current[threadId];
    if (!page?.hasMore || page.loadingOlder || page.cursor == null) return;

    updateHistoryPage(threadId, (previous) => ({ ...previous, loadingOlder: true }));
    const requestId = `history-page-${Date.now()}-${++historyRequestSeqRef.current}`;
    historyOlderRequestsRef.current.set(threadId, requestId);
    bridge.current.sendLoadSessionPage(threadId, threadId, page.cursor, 50, requestId, projectForThreadId(threadId));
    const existingTimer = olderPageRetryTimers.current.get(threadId);
    if (existingTimer !== undefined) window.clearTimeout(existingTimer);
    const timer = window.setTimeout(() => {
      if (historyOlderRequestsRef.current.get(threadId) === requestId) {
        historyOlderRequestsRef.current.delete(threadId);
        historyRequiresRequestIdRef.current.add(threadId);
        updateHistoryPage(threadId, (previous) => ({ ...previous, loadingOlder: false }));
        olderPageRetryTimers.current.delete(threadId);
      }
    }, 15_000);
    olderPageRetryTimers.current.set(threadId, timer);
  }, [updateHistoryPage, projectForThreadId]);

  const requestIdeContextFor = useCallback((threadId: string) => {
    if (!capabilityContract.ide) return;
    const requestId = `ide-${Date.now()}-${++ideRequestSeq.current}`;
    latestIdeRequest.current = requestId;
    bridge.current.requestIdeContext(requestId, threadId, projectForThreadId(threadId));
  }, [capabilityContract.ide, projectForThreadId]);

  const refreshIdeContext = useCallback(() => {
    requestIdeContextFor(currentThreadIdRef.current);
  }, [requestIdeContextFor]);

  const setSelectionVisible = useCallback((visible: boolean) => {
    selectionVisibleRef.current = visible;
    setSelectionVisibleState(visible);
  }, []);

  const searchWorkspace = useCallback((query: string) => {
    if (!capabilityContract.workspace) return;
    const threadId = currentThreadIdRef.current;
    // 立即回显查询 + loading（UI 不迟钝）；真正发往 R 的搜索防抖 150ms，
    // 快速输入合并成一次，避免每键触发 R 端 git+readRDS+全量搜索（Q1 优化 B）。
    setWorkspaceMentions((prev) => ({ ...prev, enabled: true, query, loading: true }));
    if (workspaceDebounceRef.current !== null) window.clearTimeout(workspaceDebounceRef.current);
    workspaceDebounceRef.current = window.setTimeout(() => {
      const requestId = `workspace-${Date.now()}-${++workspaceRequestSeq.current}`;
      latestWorkspaceRequest.current = requestId;
      bridge.current.searchWorkspace(requestId, threadId, query, ["file", "folder"], 50, projectForThreadId(threadId));
    }, 150);
  }, [capabilityContract.workspace, projectForThreadId]);

  // 确保初始线程在列表里
  useEffect(() => {
    setThreads((prev) => {
      if (prev.some((t) => t.id === currentThreadId)) return prev;
      const project = workspaceMode ? workingDirRef.current || undefined : undefined;
      if (project) threadProjectsRef.current.set(currentThreadId, project);
      const next = [
        {
          id: currentThreadId, status: "regular" as const, title: "New chat",
          ...(project ? { custom: { project, projectLabel: projectLabel(project) } } : {}),
        },
        ...prev,
      ];
      saveThreads(inputId, usesClientPersistence, next);
      return next;
    });
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // 消息 Map（threadId → messages）
  const [messagesMap, setMessagesMap] = useState<Record<string, ThreadMessageLike[]>>(() => {
    const saved = loadThreads(inputId, usesClientPersistence);
    const map: Record<string, ThreadMessageLike[]> = {};
    const ids = saved.length > 0 ? saved.map((t) => t.id) : [currentThreadId];
    for (const id of ids) {
      map[id] = loadMessages(inputId, usesClientPersistence, id);
    }
    return map;
  });
  // Keep one explicit registry independent of which thread is currently bound
  // by ExternalStoreRuntime. It includes restored/local and archived entries.
  for (const thread of threads) knownThreadIdsRef.current.add(thread.id);
  for (const thread of archivedThreads) knownThreadIdsRef.current.add(thread.id);
  knownThreadIdsRef.current.add(currentThreadId);

  const [submissionRevision, setSubmissionRevision] = useState(0);
  const [runningThreads, setRunningThreads] = useState<Set<string>>(new Set());
  const [runPhaseMap, setRunPhaseMap] = useState<Record<string, RunPhase>>({});
  const runPhaseMapRef = useRef<Record<string, RunPhase>>({});
  runPhaseMapRef.current = runPhaseMap;
  const [runStageMap, setRunStageMap] = useState<Record<string, RunStage>>({});
  const runStageMapRef = useRef<Record<string, RunStage>>({});
  runStageMapRef.current = runStageMap;
  const [runQueuePositionMap, setRunQueuePositionMap] = useState<Record<string, number>>({});
  const runQueuePositionMapRef = useRef<Record<string, number>>({});
  runQueuePositionMapRef.current = runQueuePositionMap;
  const [dismissedChecklistRevisions, setDismissedChecklistRevisions] = useState<Record<string, string>>({});
  const runPhase = runPhaseMap[currentThreadId];
  const runStage = runStageMap[currentThreadId];
  const runQueuePosition = runQueuePositionMap[currentThreadId];
  const isRunning = usesRunStateProtocol
    ? runPhase === "running"
    : runningThreads.has(currentThreadId);
  const isRunWaiting = usesRunStateProtocol &&
    (runPhase === "queued" || runPhase === "connecting");
  const setThreadRunning = useCallback((threadId: string, running: boolean) => {
    setRunningThreads((previous) => {
      const next = new Set(previous);
      if (running) next.add(threadId); else next.delete(threadId);
      return next;
    });
  }, []);
  const setThreadRunPhase = useCallback((threadId: string, phase: RunPhase, stage?: RunStage, queuePosition?: number) => {
    const nextPhases = { ...runPhaseMapRef.current, [threadId]: phase };
    runPhaseMapRef.current = nextPhases;
    setRunPhaseMap(nextPhases);
    const nextStages = { ...runStageMapRef.current };
    if (stage) nextStages[threadId] = stage; else delete nextStages[threadId];
    runStageMapRef.current = nextStages;
    setRunStageMap(nextStages);
    const nextQueuePositions = { ...runQueuePositionMapRef.current };
    if (typeof queuePosition === "number") nextQueuePositions[threadId] = queuePosition;
    else delete nextQueuePositions[threadId];
    runQueuePositionMapRef.current = nextQueuePositions;
    setRunQueuePositionMap(nextQueuePositions);
  }, []);
  // Static starter suggestions from assistantUIServer(suggestions=) show on the welcome
  // screen; on_done(suggestions=) replaces them after a turn. Accepts strings or {prompt, text}.
  // 归一化 suggestions:接受字符串或 {prompt, text}(欢迎屏 config + onDone + :suggestions 频道共用)
  const normalizeSuggestions = (arr: unknown[] | undefined): Array<{ prompt: string; text?: string }> =>
    (((arr as unknown[]) ?? [])
      .map((x) => {
        if (typeof x === "string") return { prompt: x, text: x };
        const o = x as { prompt?: unknown; text?: unknown };
        const prompt = String(o?.prompt ?? o?.text ?? "");
        return { prompt, text: String(o?.text ?? prompt) };
      })
      .filter((x) => x.prompt) as Array<{ prompt: string; text?: string }>);
  const initialSuggestions = normalizeSuggestions(config?.suggestions as unknown[]);
  type Suggestion = { prompt: string; text?: string };
  type Artifact = { id: string; title: string; type: string; content: string; lang?: string };
  const [suggestionsMap, setSuggestionsMap] = useState<Record<string, Suggestion[]>>({});
  const suggestions = suggestionsMap[currentThreadId] ?? initialSuggestions;
  const [artifactsMap, setArtifactsMap] = useState<Record<string, Artifact[]>>({});
  const [activeArtifactIds, setActiveArtifactIds] = useState<Record<string, string | null>>({});
  const artifacts = artifactsMap[currentThreadId] ?? [];
  const activeArtifactId = activeArtifactIds[currentThreadId] ?? null;

  // ── ClaudeAgentSDK 能力对齐状态 ────────────────────────────────────────────
  type UsageInfo = { costUsd?: number; tokens?: number; contextTokens?: number; turns?: number; durationMs?: number; model?: string; contextWindow?: number };
  const [usageMap, setUsageMap] = useState<Record<string, UsageInfo>>({});          // #1 每线程最新用量
  const [agentStateMap, setAgentStateMap] = useState<Record<string, unknown>>({});   // Plan 36 每线程 agent 状态
  const [taskMonitorState, setTaskMonitorState] = useState(createTaskMonitorState);
  const taskMonitorStateRef = useRef(taskMonitorState);
  taskMonitorStateRef.current = taskMonitorState;
  const [latestTaskActivityIds, setLatestTaskActivityIds] = useState<Record<string, string>>({});
  const clearLatestTaskActivity = useCallback((threadId: string) => {
    setLatestTaskActivityIds((previous) => {
      if (!(threadId in previous)) return previous;
      const next = { ...previous };
      delete next[threadId];
      return next;
    });
  }, []);
  type RateLimitState = { status?: string; resetsAt?: string; utilization?: number; type?: string };
  const [rateLimitMap, setRateLimitMap] = useState<Record<string, RateLimitState | null>>({});
  const [statusTextMap, setStatusTextMap] = useState<Record<string, string | null>>({});
  const rateLimit = rateLimitMap[currentThreadId] ?? null;
  const statusText = statusTextMap[currentThreadId] ?? null;
  const [warmingThreads, setWarmingThreads] = useState<Set<string>>(new Set());      // 每线程冷启动中
  const [warmingResumingThreads, setWarmingResumingThreads] = useState<Set<string>>(new Set()); // 冷启动中且为"恢复历史"（非全新）
  const [serverCommandsByThread, setServerCommandsByThread] = useState<Record<string, Array<{ name: string; description?: string }>>>({});
  const streamingIdsRef = useRef<Record<string, string | null>>({});
  const manualTitleIds  = useRef<Set<string>>(new Set()); // 用户手动重命名过的线程
  type QueuedMessage = {
    text: string;
    sendText: string;
    project?: string;
    continuationKind?: AutoContinueKind;
  };
  const messageQueueRef = useRef<Map<string, QueuedMessage[]>>(new Map()); // 每线程排队消息
  const autoContinueRunIdsRef = useRef(new Set<string>());
  type PendingSubmission = {
    id: string;
    requiresService: boolean;
    userMessageId: string;
    threadId: string;
    displayText: string;
    sendText: string;
    attachmentData: AttachmentData[];
    storedAttachments: unknown[];
    quote?: QuoteInfo;
    selectionVisible: boolean;
    project?: string;
    continuationKind?: AutoContinueKind;
    original?: AppendMessage;
  };
  const pendingSubmissionsRef = useRef<PendingSubmission[]>([]);
  const deferredSubmissionInFlightRef = useRef(new Map<string, { id: string; runId?: string }>());
  const deferredSubmissionSeq = useRef(0);
  const messageIdSeq = useRef(0);
  const [pendingServiceSubmissions, setPendingSubmissions] = useState(0);
  const drainPendingSubmissionsRef = useRef<() => void>(() => {});
  const advancePendingSubmissionsRef = useRef<(threadId: string, runId: string, flushMessages: boolean) => void>(() => {});
  const cancelPendingSubmissions = useCallback((threadId?: string) => {
    const removed = threadId
      ? pendingSubmissionsRef.current.filter((item) => item.threadId === threadId)
      : pendingSubmissionsRef.current;
    if (removed.length === 0) return;
    pendingSubmissionsRef.current = threadId
      ? pendingSubmissionsRef.current.filter((item) => item.threadId !== threadId)
      : [];
    bridge.current.cancelReservedSubmissions(removed.map((item) => item.id));
    const removedByThread = new Map<string, Set<string>>();
    for (const item of removed) {
      const ids = removedByThread.get(item.threadId) ?? new Set<string>();
      ids.add(item.userMessageId);
      removedByThread.set(item.threadId, ids);
    }
    setMessagesMap((previous) => {
      const next = { ...previous };
      for (const [tid, ids] of removedByThread) {
        const updated = (next[tid] ?? []).filter((message) => !message.id || !ids.has(message.id));
        next[tid] = updated;
        if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, tid, updated);
      }
      return next;
    });
    setPendingSubmissions(pendingSubmissionsRef.current.length);
  }, [inputId]);

  const clearProactiveThreadTracking = useCallback((threadId: string) => {
    proactiveRevisionsRef.current.delete(threadId);
    proactiveBeforeSessionsRef.current.delete(threadId);
    proactiveAfterRunRef.current.delete(threadId);
    proactiveSkipNextHistoryRefreshRef.current.delete(threadId);
    delete completedRunIdsRef.current[threadId];
  }, []);

  const invalidateHistoryForProactive = useCallback((threadId: string) => {
    const initialTimer = sessionLoadRetryTimers.current.get(threadId);
    if (initialTimer !== undefined) window.clearTimeout(initialTimer);
    const olderTimer = olderPageRetryTimers.current.get(threadId);
    if (olderTimer !== undefined) window.clearTimeout(olderTimer);
    sessionLoadRetryTimers.current.delete(threadId);
    olderPageRetryTimers.current.delete(threadId);
    if (historyReplaceRequestsRef.current.has(threadId) ||
        historyOlderRequestsRef.current.has(threadId)) {
      historyRequiresRequestIdRef.current.add(threadId);
    }
    historyReplaceRequestsRef.current.delete(threadId);
    historyOlderRequestsRef.current.delete(threadId);
    sessionLoadStates.current.set(threadId, "loaded");
    updateHistoryPage(threadId, () => ({
      reading: false, hasMore: false, cursor: null, loadingOlder: false,
    }));
  }, [updateHistoryPage]);

  const normalizeProactiveMessages = useCallback((
    messages: unknown[],
    revision: number,
  ): ThreadMessageLike[] => {
    const used = new Set<string>();
    return messages
      .filter((message): message is Record<string, unknown> =>
        Boolean(message) && typeof message === "object")
      .map((message, index) => {
        const rawId = typeof message.id === "string" && message.id.length > 0
          ? message.id
          : `proactive-${revision}-${index + 1}`;
        let id = rawId;
        let duplicate = 1;
        while (used.has(id)) id = `${rawId}--proactive-${++duplicate}`;
        used.add(id);
        return { ...message, id } as ThreadMessageLike;
      });
  }, []);

  const commitProactiveReplacement = useCallback((payload: ProactiveMessagesPayload) => {
    const threadId = payload.threadId;
    if (deletedThreadIdsRef.current.has(threadId) ||
        !knownThreadIdsRef.current.has(threadId)) return;

    invalidateHistoryForProactive(threadId);
    if (threadId !== currentThreadIdRef.current && serverSessionIdsRef.current.has(threadId)) {
      // The authoritative replacement satisfies the first hydration. A later
      // revisit still performs an explicit refresh.
      proactiveSkipNextHistoryRefreshRef.current.add(threadId);
    }

    setMessagesMap((previous) => {
      const incoming = normalizeProactiveMessages(payload.messages, payload.revision);
      const incomingIds = new Set(
        incoming.map((message) => message.id)
          .filter((id): id is string => typeof id === "string"),
      );
      const pendingUserIds = new Set(
        pendingSubmissionsRef.current
          .filter((submission) => submission.threadId === threadId)
          .map((submission) => submission.userMessageId),
      );
      const pendingUsers = (previous[threadId] ?? []).filter((message) =>
        message.role === "user" && typeof message.id === "string" &&
        pendingUserIds.has(message.id) && !incomingIds.has(message.id)
      );
      const updated = normalizeProactiveMessages(
        [...incoming, ...pendingUsers],
        payload.revision,
      );
      if (usesClientPersistence) {
        saveMessages(inputId, usesClientPersistence, threadId, updated);
      }
      return { ...previous, [threadId]: updated };
    });
  }, [inputId, invalidateHistoryForProactive, normalizeProactiveMessages, usesClientPersistence]);

  const handleProactiveReplacement = useCallback((payload: ProactiveMessagesPayload) => {
    if (payload?.version !== 1 || payload.operation !== "replace" ||
        typeof payload.threadId !== "string" || payload.threadId.length === 0 ||
        !Number.isSafeInteger(payload.revision) || payload.revision < 0 ||
        !Array.isArray(payload.messages) ||
        (payload.afterRunId !== undefined && typeof payload.afterRunId !== "string")) return;

    const threadId = payload.threadId;
    if (deletedThreadIdsRef.current.has(threadId)) return;
    if (!knownThreadIdsRef.current.has(threadId)) {
      if (!hasSessionsSnapshotRef.current) {
        const buffered = proactiveBeforeSessionsRef.current.get(threadId) ?? [];
        buffered.push(payload);
        proactiveBeforeSessionsRef.current.set(threadId, buffered);
      }
      return;
    }

    const appliedRevision = proactiveRevisionsRef.current.get(threadId);
    const queuedRevision = proactiveAfterRunRef.current.get(threadId)?.revision;
    const previousRevision = Math.max(appliedRevision ?? -1, queuedRevision ?? -1);
    if (payload.revision <= previousRevision) return;

    if (activeRunsRef.current.has(threadId)) {
      const activeRunId = activeTaskRunIdsRef.current[threadId];
      if (!payload.afterRunId || payload.afterRunId !== activeRunId) return;
      proactiveAfterRunRef.current.set(threadId, payload);
      return;
    }

    if (payload.afterRunId && completedRunIdsRef.current[threadId] !== payload.afterRunId) return;
    proactiveRevisionsRef.current.set(threadId, payload.revision);
    commitProactiveReplacement(payload);
  }, [commitProactiveReplacement]);

  const actionAckRefs = useRef(new Map<string, {
    threadId: string;
    ackId: string;
    actionId: string;
    startedAt?: number;
    timeoutId?: number;
  }>());
  const [blockingActions, setBlockingActions] = useState<Record<string, BlockingAction>>({});
  const blockingActionsRef = useRef<Record<string, BlockingAction>>({});
  const setBlockingActionForThread = useCallback((threadId: string, action?: BlockingAction) => {
    const next = { ...blockingActionsRef.current };
    if (action) next[threadId] = action;
    else delete next[threadId];
    blockingActionsRef.current = next;
    setBlockingActions(next);
  }, []);
  useEffect(() => () => {
    for (const target of actionAckRefs.current.values()) {
      if (target.timeoutId !== undefined) window.clearTimeout(target.timeoutId);
    }
  }, []);
  const invokeActionRef = useRef<((item: ActionItemDef) => void) | null>(null);
  const actionRequestSeq = useRef(0);
  type PermissionPending = { requestId: string; requested: string };
  const [permissionValues, setPermissionValues] = useState<Record<string, string>>({});
  const [permissionPending, setPermissionPending] = useState<Record<string, PermissionPending>>({});
  const [permissionErrors, setPermissionErrors] = useState<Record<string, string | null>>({});
  const [thinkingValue, setThinkingValue] = useState<string | undefined>(undefined);  // 乐观显示值
  type ModelPending = { requestId: string; requested: string };
  const [modelValues, setModelValues] = useState<Record<string, string>>({});
  const [modelPending, setModelPending] = useState<Record<string, ModelPending>>({});
  const [modelErrors, setModelErrors] = useState<Record<string, string | null>>({});
  const [modelPickerOpen, setModelPickerOpen] = useState(false);                       // /model 弹选择器
  const permissionPendingRef = useRef<Record<string, PermissionPending>>({});
  const permissionRequestsRef = useRef(new Map<string, { threadId: string; requested: string }>());
  const modelPendingRef = useRef<Record<string, ModelPending>>({});
  const modelRequestsRef = useRef(new Map<string, { threadId: string; requested: string }>());
  const makeActionRequestId = () => `action-${Date.now()}-${++actionRequestSeq.current}`;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const deliverTextRef  = useRef<((text: string, threadId: string, project?: string, sendText?: string, continuationKind?: AutoContinueKind) => void) | null>(null);
  // 正在 streaming 的 threadId 集合（含后台并发 run）。用于：
  // ① 多 tab storage 同步时保护正在跑的线程不被磁盘旧值覆盖；
  // per-thread run 序号也用于拒绝晚到的历史快照覆盖请求后启动的 live run。

  // 多 tab 同步：监听 storage 事件（仅其它 tab 写同源 localStorage 时触发，本 tab 不触发）。
  // 避免两个 tab 各持独立 state、last-write-wins 互相覆盖对方新建/删除的线程。
  // 策略：threads/archived 列表直接 reload 保持侧栏一致；某 thread 的消息仅在它
  // 不在本 tab 正在 streaming 时才同步（正在跑的线程本地领先磁盘，防覆盖流式中消息）。
  useEffect(() => {
    if (!usesClientPersistence) return; // server/none 模式不用 localStorage
    const prefix = storageKey(inputId, "");
    const onStorage = (e: StorageEvent) => {
      if (!usesClientPersistence || !e.key || !e.key.startsWith(prefix)) return;
      const suffix = e.key.slice(prefix.length);
      if (suffix === "threads") {
        setThreads(loadThreads(inputId, usesClientPersistence));
      } else if (suffix === "archived") {
        setArchivedThreads(loadArchivedThreads(inputId, usesClientPersistence));
      } else if (suffix.startsWith("msgs:")) {
        const tid = suffix.slice("msgs:".length);
        // 正在 streaming 的线程（含后台并发 run）本地领先磁盘，跳过同步防覆盖；
        // 当前活动线程也跳过（用户正在看/可能将发消息）。
        if (activeRunsRef.current.has(tid) || tid === currentThreadIdRef.current) return;
        setMessagesMap((prev) => ({ ...prev, [tid]: loadMessages(inputId, usesClientPersistence, tid) }));
      }
    };
    window.addEventListener("storage", onStorage);
    return () => window.removeEventListener("storage", onStorage);
  }, [inputId]);

  // 当前线程消息
  const messages = useMemo(
    () => messagesMap[currentThreadId] ?? [],
    [messagesMap, currentThreadId]
  );

  // 更新消息并持久化（server mode 下跳过写 localStorage）
  const setCurrentMessages = useCallback(
    (updater: (prev: ThreadMessageLike[]) => ThreadMessageLike[]) => {
      setMessagesMap((prev) => {
        const updated = updater(prev[currentThreadId] ?? []);
        if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, currentThreadId, updated);
        return { ...prev, [currentThreadId]: updated };
      });
    },
    [inputId, currentThreadId]
  );

  // ── 切换到第一个可用线程或新建 ────────────────────────────────────────────
  const switchAwayFrom = useCallback(
    (
      removedId: string,
      currentThreads: ExternalStoreThreadData<"regular">[],
      preserveRemovedDraft = true,
    ) => {
      const remaining = currentThreads.filter((t) => t.id !== removedId);
      if (remaining.length > 0) {
        switchCurrentThread(remaining[0].id, preserveRemovedDraft);
      } else {
      const newId = makeThreadId();
        knownThreadIdsRef.current.add(newId);
        thisSessionThreadIds.current.add(newId);
        const newThread: ExternalStoreThreadData<"regular"> = {
          id: newId,
          status: "regular",
          title: "New chat",
        };
        setThreads((prev) => {
          const next = [newThread, ...prev.filter((t) => t.id !== removedId)];
          saveThreads(inputId, usesClientPersistence, next);
          return next;
        });
        switchCurrentThread(newId, preserveRemovedDraft);
      }
    },
    [inputId, switchCurrentThread]
  );

  // ── 注册 clear（新建线程）────────────────────────────────────────────────
  useEffect(() => {
    bridge.current.onClear(() => {
      const newId = makeThreadId();
      knownThreadIdsRef.current.add(newId);
      thisSessionThreadIds.current.add(newId);
      const newThread: ExternalStoreThreadData<"regular"> = {
        id: newId,
        status: "regular",
        title: "New chat",
      };
      setThreads((prev) => {
        const next = [newThread, ...prev];
        saveThreads(inputId, usesClientPersistence, next);
        return next;
      });
      switchCurrentThread(newId);
    });

    // ── 注册 :action-result（permission 静默状态 / 普通动作 ack）───────────────
    bridge.current.onActionResult((result) => {
      const requestId = result.requestId;
      const permissionRequest = requestId
        ? permissionRequestsRef.current.get(requestId)
        : undefined;
      if (permissionRequest) {
        const { threadId: tid, requested } = permissionRequest;
        const latest = permissionPendingRef.current[tid];
        if (!latest || latest.requestId !== requestId) {
          permissionRequestsRef.current.delete(requestId!);
          return;
        }
        if (result.status === "progress") return;
        permissionRequestsRef.current.delete(requestId!);

        if (result.status === "error") {
          setPermissionErrors((prev) => ({
            ...prev,
            [tid]: result.message || "Permission mode request failed",
          }));
        } else if (result.status !== "progress") {
          const canonical = typeof result.value === "string" ? result.value : requested;
          setPermissionValues((prev) => ({ ...prev, [tid]: canonical }));
          setPermissionErrors((prev) => ({ ...prev, [tid]: null }));
        } else {
          return;
        }
        const nextPending = { ...permissionPendingRef.current };
        delete nextPending[tid];
        permissionPendingRef.current = nextPending;
        setPermissionPending(nextPending);
        return;
      }

      const modelRequest = requestId
        ? modelRequestsRef.current.get(requestId)
        : undefined;
      if (modelRequest) {
        const latest = modelPendingRef.current[modelRequest.threadId];
        if (!latest || latest.requestId !== requestId) {
          modelRequestsRef.current.delete(requestId!);
          return;
        }
        if (result.status === "progress") return;
        modelRequestsRef.current.delete(requestId!);
        const nextPending = { ...modelPendingRef.current };
        delete nextPending[modelRequest.threadId];
        modelPendingRef.current = nextPending;
        setModelPending(nextPending);
        if (result.status === "error") {
          setModelErrors((previous) => ({
            ...previous,
            [modelRequest.threadId]: result.message || "Model change failed",
          }));
        } else {
          const canonical = typeof result.value === "string"
            ? result.value
            : modelRequest.requested;
          setModelValues((previous) => ({
            ...previous,
            [modelRequest.threadId]: canonical,
          }));
          setModelErrors((previous) => ({
            ...previous,
            [modelRequest.threadId]: null,
          }));
        }
        return;
      }

      const target = requestId ? actionAckRefs.current.get(requestId) : undefined;
      if (!target) return;

      if (target.actionId === "compact") {
        const incoming = result.value && typeof result.value === "object"
          ? result.value as Partial<CompactActionProgress>
          : undefined;
        const fallbackPhase: CompactPhase = result.status === "error"
          ? "error"
          : result.status === "progress" ? "compacting" : "complete";
        const phase = isCompactPhase(incoming?.phase) ? incoming.phase : fallbackPhase;
        const startedAt = target.startedAt ?? (
          typeof incoming?.startedAt === "number" && Number.isFinite(incoming.startedAt)
            ? incoming.startedAt
            : Date.now()
        );
        const data: CompactActionProgress = {
          kind: "compact",
          phase,
          startedAt,
          ...(result.message || incoming?.message
            ? { message: result.message || incoming?.message }
            : {}),
        };
        setMessagesMap((prev) => {
          const msgs = prev[target.threadId] ?? [];
          const updated = msgs.map((m): ThreadMessageLike =>
            m.id === target.ackId
              ? ({ ...m, content: [{ type: "data-action-progress", data }] } as any)
              : m,
          );
          if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, target.threadId, updated);
          return { ...prev, [target.threadId]: updated };
        });
        if (phase === "starting" || phase === "compacting") {
          setBlockingActionForThread(target.threadId, data as BlockingAction);
        } else {
          if (target.timeoutId !== undefined) window.clearTimeout(target.timeoutId);
          setBlockingActionForThread(target.threadId);
          actionAckRefs.current.delete(requestId!);
        }
        return;
      }

      if (!result.message) return;
      const prefix = result.status === "error" ? "\u26a0\ufe0f"
        : result.status === "progress" ? "\u23f3"
        : "\u2713";
      const renderedMessage = result.message.includes("\n")
        ? `${prefix}\n\n${result.message}`
        : `${prefix} ${result.message}`;
      setMessagesMap((prev) => {
        const msgs = prev[target.threadId] ?? [];
        const updated = msgs.map((m): ThreadMessageLike =>
          m.id === target.ackId
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            ? ({ ...m, content: [{ type: "text" as const, text: renderedMessage }] } as any)
            : m,
        );
        if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, target.threadId, updated);
        return { ...prev, [target.threadId]: updated };
      });
      if (result.status !== "progress") actionAckRefs.current.delete(requestId!);
      const effect = result.value && typeof result.value === "object"
        ? (result.value as { effect?: unknown }).effect
        : undefined;
      if (result.status !== "error" && result.status !== "progress" &&
          effect === "new-thread" && target.threadId === currentThreadIdRef.current) {
        switchToNewThread();
      }
    });

    // ── #1 用量/成本 ─────────────────────────────────────────────────────────
    bridge.current.onUsage((d) => {
      const tid = d.threadId ?? currentThreadIdRef.current;
      setUsageMap((prev) => ({ ...prev, [tid]: {
        costUsd: d.costUsd, tokens: d.tokens, turns: d.turns, durationMs: d.durationMs, model: d.model,
        contextTokens: d.contextTokens,
        contextWindow: d.contextWindow,
      } }));
    });
    // ── Plan 36 Agent 共享状态(per-thread 快照)───────────────────────────────
    bridge.current.onStateSnapshot((d) => {
      const tid = d.threadId ?? currentThreadIdRef.current;
      setAgentStateMap((prev) => ({ ...prev, [tid]: d.state }));
    });
    // ── #2 子agent/Task 进度 ──────────────────────────────────────────────────
    bridge.current.onTask((d) => {
      const tid = d.threadId ?? currentThreadIdRef.current;
      setTaskMonitorState((previous) => reduceTaskMonitorEvent(previous, {
        threadId: tid,
        taskId: d.taskId,
        kind: d.kind,
        description: d.description,
        status: d.status,
        toolName: d.toolName,
        summary: d.summary,
      }));
      const activeRunId = activeTaskRunIdsRef.current[tid];
      if (
        activeRunId
        && (!d.runId || d.runId === activeRunId)
        && isTaskTerminalStatus(d.status)
      ) {
        setLatestTaskActivityIds((previous) => ({ ...previous, [tid]: d.taskId }));
      }
    });
    // ── #3 限流告警 ───────────────────────────────────────────────────────────
    bridge.current.onRateLimit((d) => {
      const tid = d.threadId ?? currentThreadIdRef.current;
      if (deletedThreadIdsRef.current.has(tid)) return;
      const limited = d.status && !/^(allowed|ok|none)$/i.test(d.status);
      setRateLimitMap((previous) => ({
        ...previous,
        [tid]: limited
          ? { status: d.status, resetsAt: d.resetsAt, utilization: d.utilization, type: d.type }
          : null,
      }));
    });
    // ── #4 系统状态行 ─────────────────────────────────────────────────────────
    bridge.current.onStatus((d) => {
      const tid = d.threadId ?? currentThreadIdRef.current;
      if (deletedThreadIdsRef.current.has(tid)) return;
      // Run-scoped statuses can arrive late from the CLI after done. Never let
      // them resurrect a terminal thread's status line; persistent statuses
      // (hooks, background work, compaction) remain independently visible.
      const statusKind = d.status === "status" && typeof d.text === "string"
        ? d.text
        : d.status;
      if (RUN_SCOPED_TRANSIENT_STATUSES.has(statusKind) &&
          !activeRunsRef.current.has(tid)) {
        setStatusTextMap((previous) => ({ ...previous, [tid]: null }));
        return;
      }
      const label = d.text || (statusKind === "thinking_tokens" ? "Thinking\u2026"
        : statusKind === "init" ? "Initializing\u2026" : statusKind);
      setStatusTextMap((previous) => ({ ...previous, [tid]: label ?? null }));
    });
    // ── 每线程冷启动指示 ──────────────────────────────────────────────────────
    bridge.current.onRunState((d) => {
      if (!d.threadId || !d.runId || deletedThreadIdsRef.current.has(d.threadId)) return;
      if (activeTaskRunIdsRef.current[d.threadId] !== d.runId) return;
      const previousPhase = runPhaseMapRef.current[d.threadId];
      const previousStage = runStageMapRef.current[d.threadId];
      if (previousPhase === "complete" || previousPhase === "error" || previousPhase === "cancelled") return;
      if (previousPhase === "running" && (d.phase === "queued" || d.phase === "connecting")) return;
      if (previousStage === "finalizing" && d.stage === "streaming") return;
      setThreadRunPhase(d.threadId, d.phase, d.stage, d.queuePosition);
      if (d.phase === "running") setThreadRunning(d.threadId, true);
      if (d.phase === "complete" || d.phase === "error" || d.phase === "cancelled") {
        setThreadRunning(d.threadId, false);
      }
    });
    bridge.current.onWarming((d) => {
      const tid = d.threadId ?? currentThreadIdRef.current;
      setWarmingThreads((prev) => {
        const next = new Set(prev);
        if (d.active) next.add(tid); else next.delete(tid);
        return next;
      });
      setWarmingResumingThreads((prev) => {
        const next = new Set(prev);
        if (d.active && d.resuming) next.add(tid); else next.delete(tid);
        return next;
      });
    });
    // "Run in Console" 结果回流：自动提交一条消息把代码+输出报告给 Claude(Plan 21/A)。
    bridge.current.onConsoleResult((d) => {
      const threadId = d.threadId ?? currentThreadIdRef.current;
      const code = String(d?.code ?? "");
      const ok = d?.ok === true;
      const body = ok
        ? (String(d?.output ?? "").trim() || "(no visible output)")
        : `Error: ${String(d?.error ?? "").trim()}`;
      const text = [
        "I ran this in my R console:",
        "```r", code, "```",
        ok ? "Output:" : "It errored:",
        "```", body, "```",
      ].join("\n");
      deliverTextRef.current?.(text, threadId, d.project ?? projectForThreadId(threadId));
    });
    // 本地 skills 热更新(切换工作目录时 R 重载该项目 .claude 的 skills 并经 :commands 下发)。
    bridge.current.onCommands((d) => {
      setCommands(((d.commands ?? []) as CommandDef[]) ?? []);
    });
    // ── #5 命令自动发现 ───────────────────────────────────────────────────────
    // Plan 48B: R 端 on_suggestions(...) 经 :suggestions 频道随时推送 follow-up 建议。
    // Store by owner thread even when it is currently in the background.
    bridge.current.onSuggestions((d) => {
      const tid = d.threadId ?? currentThreadIdRef.current;
      if (deletedThreadIdsRef.current.has(tid)) return;
      setSuggestionsMap((previous) => ({
        ...previous,
        [tid]: normalizeSuggestions(d.suggestions as unknown[]),
      }));
    });
    if (copilotBridge.current) {
      copilotBridge.current.onStatus((next) => {
        serviceStateRef.current = next;
        setServiceState(next);
        setAutoStartCopilotApiState(next.autoStart);
        if (next.status === "disabled") cancelPendingSubmissions();
        if (next.status === "ready") queueMicrotask(() => drainPendingSubmissionsRef.current());
      });
      // The addin-owned R service does not start until this status subscriber is
      // installed, so no initial checking/starting/ready publication can be lost.
      copilotBridge.current.sendReady();
    }
    bridge.current.onServerCommands((d) => {
      const tid = d.threadId ?? currentThreadIdRef.current;
      const cmds = (d.commands ?? []) as Array<Record<string, unknown>>;
      const mapped = cmds.map((c) => ({
        name: String(c.name ?? c.command ?? ""),
        description: (c.description ?? c.summary) as string | undefined,
      })).filter((c) => c.name);
      setServerCommandsByThread((previous) => ({ ...previous, [tid]: mapped }));
    });
    bridge.current.onIdeContext((data) => {
      if (!data.requestId || data.requestId !== latestIdeRequest.current) return;
      if (data.threadId && data.threadId !== currentThreadIdRef.current) return;
      setIdeContext(data);
    });
    bridge.current.onWorkspaceResults((data) => {
      if (!data.requestId || data.requestId !== latestWorkspaceRequest.current) return;
      if (data.threadId && data.threadId !== currentThreadIdRef.current) return;
      setWorkspaceMentions((prev) => ({
        ...prev, items: Array.isArray(data.items) ? data.items : [], loading: false,
      }));
    });

    // ── 注册 :working-dir（工作目录切换：更新显示 + 清本次实例的本地线程，
    //    随后到达的 :sessions 会用新目录的会话替换整份列表）──────────────────
    bridge.current.onWorkingDir((d) => {
      if (typeof d?.dir === "string") {
        workingDirRef.current = d.dir;
        setWorkingDirState(d.dir);
        setGitBranch(undefined);
        if (workspaceMode) {
          setWorkspaceProjectOrder((previous) =>
            previous.includes(d.dir!) ? previous : [d.dir!, ...previous]
          );
        }
      }
      if (Array.isArray(d?.recent)) setRecentDirs(d.recent as string[]);
      if (!workspaceMode) {
        // Ordinary Chat owns one cwd, so queued work and local threads cannot cross it.
        cancelPendingSubmissions();
        messageQueueRef.current.clear();
        composerDraftsRef.current.clear();
        runtimeRef.current?.thread.composer.setText("");
        thisSessionThreadIds.current.clear();
      }
    });
    bridge.current.onGitBranch((data) => {
      if (typeof data?.project !== "string" ||
          data.project !== workingDirRef.current) return;
      setGitBranch(
        typeof data.branch === "string" && data.branch.length > 0
          ? data.branch
          : undefined,
      );
    });
    bridge.current.onProjects((d) => {
      if (Array.isArray(d?.projects)) setProjects(d.projects as string[]);
    });
    bridge.current.onProactiveMessages(handleProactiveReplacement);
    // ── 注册 :sessions（侧边栏注入历史 Claude session）─────────────────────
    // 策略：server 列表到达时【替换】localStorage 线程，而非追加。
    // 只保留本次 React 实例新建（thisSessionThreadIds）且尚未在 server 上的线程，
    // 避免旧 localStorage 孤儿线程（t_XXXX）和 server sessions（UUID）同时显示。
    bridge.current.onSessions(({ sessions: incomingSessions, projectOrder }: SessionsPayload) => {
      hasSessionsSnapshotRef.current = true;
      const sessions = incomingSessions.filter((session) =>
        !deletedThreadIdsRef.current.has(session.id)
      );
      if (workspaceMode && Array.isArray(projectOrder)) {
        setWorkspaceProjectOrder(Array.from(new Set(
          projectOrder.filter((project): project is string =>
            typeof project === "string" && project.length > 0
          ),
        )));
      }
      // In explicit server mode even an empty snapshot is authoritative: discard
      // every previously displayed server/local thread instead of treating the
      // payload as "no update". Keep one fresh blank thread so the runtime always
      // has a valid mainThreadId.
      if (sessions.length === 0) {
        if (persistence !== "server") return;
        cancelPendingSubmissions();
        messageQueueRef.current.clear();
        for (const timer of sessionLoadRetryTimers.current.values()) {
          window.clearTimeout(timer);
        }
        sessionLoadRetryTimers.current.clear();
        for (const timer of olderPageRetryTimers.current.values()) {
          window.clearTimeout(timer);
        }
        olderPageRetryTimers.current.clear();
        for (const trackedId of new Set([
          ...sessionLoadStates.current.keys(),
          ...historyReplaceRequestsRef.current.keys(),
          ...historyOlderRequestsRef.current.keys(),
        ])) {
          historyRequiresRequestIdRef.current.add(trackedId);
        }
        sessionLoadStates.current.clear();
        serverSessionIdsRef.current.clear();
        historyReplaceRequestsRef.current.clear();
        historyOlderRequestsRef.current.clear();
        historyPageStatesRef.current = {};
        setHistoryPageStates({});
        const newId = makeThreadId();
        for (const knownId of knownThreadIdsRef.current) {
          clearProactiveThreadTracking(knownId);
        }
        proactiveBeforeSessionsRef.current.clear();
        knownThreadIdsRef.current.clear();
        knownThreadIdsRef.current.add(newId);
        thisSessionThreadIds.current.clear();
        thisSessionThreadIds.current.add(newId);
        const project = workspaceMode ? workingDirRef.current || undefined : undefined;
        if (project) threadProjectsRef.current.set(newId, project);
        setThreads([{
          id: newId, status: "regular", title: "New chat",
          ...(project ? { custom: { project, projectLabel: projectLabel(project) } } : {}),
        }]);
        setArchivedThreads([]);
        setMessagesMap({ [newId]: [] });
        composerDraftsRef.current.clear();
        switchCurrentThread(newId, false);
        return;
      }

      const serverIds = new Set(sessions.map((s) => s.id));
      for (const session of sessions) {
        if (session.project) threadProjectsRef.current.set(session.id, session.project);
      }
      for (const trackedId of Array.from(sessionLoadStates.current.keys())) {
        if (!serverIds.has(trackedId)) clearThreadHistoryTracking(trackedId);
      }
      serverSessionIdsRef.current = serverIds;

      // 填充日期 Map（供侧边栏展示），ISO 字符串直接传入 Date 构造函数
      for (const s of sessions) {
        if (s.createdAt) {
          const d = new Date(s.createdAt);
          if (!isNaN(d.getTime())) {
            sessionDates.set(s.id, d.toLocaleDateString(undefined, {
              year: "numeric", month: "short", day: "numeric",
            }));
          }
        }
      }

      // 每个 server session 在当前页面生命周期都必须由 R 至少 hydrate 一次。
      // localStorage 缓存只用于点击后的即时展示，不能代表本次 R/SDK 生命周期
      // 已恢复 session 映射或完成 warmup；只有 :load-thread 确认后才进入 loaded。
      // 已经 loading/loaded 的条目不被后续 :sessions 快照重置。
      for (const s of sessions) {
        if (!sessionLoadStates.current.has(s.id)) {
          sessionLoadStates.current.set(s.id, "unloaded");
        }
      }

      // 方案B：按服务端权威 archived 标记分流到 active / archived 两区。
      const activeSessions = sessions.filter((s) => !s.archived);
      const archivedSessions = sessions.filter((s) => s.archived);
      const activeIds = new Set(activeSessions.map((s) => s.id));

      const serverThreads = sessionsToWorkspaceThreads(activeSessions, "regular");
      const serverArchived = sessionsToWorkspaceThreads(archivedSessions, "archived");
      const retainedLocalIds = Array.from(knownThreadIdsRef.current).filter((id) =>
        thisSessionThreadIds.current.has(id) && !serverIds.has(id) &&
        !deletedThreadIdsRef.current.has(id)
      );
      knownThreadIdsRef.current = new Set([...retainedLocalIds, ...serverIds]);

      setThreads((prev) => {
        // 保留本次 session 新建且尚未上传 server 的线程（例如用户正在输入）
        const localNew = prev.filter(
          (t) => !serverIds.has(t.id) && thisSessionThreadIds.current.has(t.id)
        );
        // 本地新建线程排前面，server 历史线程排后面
        const merged = [...localNew, ...serverThreads];
        saveThreads(inputId, usesClientPersistence, merged);
        return merged;
      });

      // 归档区完全由服务端快照决定（权威），本地不新增归档项。
      setArchivedThreads(() => {
        saveArchivedThreads(inputId, usesClientPersistence, serverArchived);
        return serverArchived;
      });

      setMessagesMap((prev) => {
        const patch: Record<string, ThreadMessageLike[]> = {};
        for (const s of sessions) {
          patch[s.id] = prev[s.id] ?? loadMessages(inputId, usesClientPersistence, s.id);
        }
        return { ...prev, ...patch };
      });

      for (const [threadId, buffered] of proactiveBeforeSessionsRef.current) {
        proactiveBeforeSessionsRef.current.delete(threadId);
        if (!knownThreadIdsRef.current.has(threadId) ||
            deletedThreadIdsRef.current.has(threadId)) continue;
        for (const payload of buffered) handleProactiveReplacement(payload);
      }

      // 当前线程若是被替换掉的 localStorage 孤儿线程，切换并加载第一个 active
      // session；本次新建的空白线程则继续保持冷启动，历史项等用户点击。
      // 注意：只看 active（归档项不该被 auto-load）。
      const cur = currentThreadIdRef.current;
      if (!serverIds.has(cur) && !thisSessionThreadIds.current.has(cur)) {
        if (activeSessions.length > 0) {
          const firstSessionId = activeSessions[0].id;
          switchCurrentThread(firstSessionId, false);
          requestSessionLoad(firstSessionId);
        }
      } else if (activeIds.has(cur)) {
        requestSessionLoad(cur);
      }
    });

    // ── 注册 :load-thread（接收 R 发来的历史消息/旧页）─────────────────────
    bridge.current.onLoadThread((data) => {
      const { threadId } = data;
      const isOlderPage = data.prepend === true;
      let requestedAtRunSeq: number | undefined;

      if (isOlderPage) {
        const pendingRequestId = historyOlderRequestsRef.current.get(threadId);
        const legacyAmbiguous = !data.requestId &&
          (pendingRequestId === undefined || historyRequiresRequestIdRef.current.has(threadId));
        if (legacyAmbiguous || (data.requestId && data.requestId !== pendingRequestId)) return;
        historyOlderRequestsRef.current.delete(threadId);
        const olderTimer = olderPageRetryTimers.current.get(threadId);
        if (olderTimer !== undefined) window.clearTimeout(olderTimer);
        olderPageRetryTimers.current.delete(threadId);
      } else {
        const pending = historyReplaceRequestsRef.current.get(threadId);
        const legacyAmbiguous = !data.requestId &&
          (pending === undefined || historyRequiresRequestIdRef.current.has(threadId));
        if (legacyAmbiguous || (data.requestId && data.requestId !== pending?.requestId)) return;
        requestedAtRunSeq = pending?.runSeq;
        historyReplaceRequestsRef.current.delete(threadId);
        const retryTimer = sessionLoadRetryTimers.current.get(threadId);
        if (retryTimer !== undefined) window.clearTimeout(retryTimer);
        sessionLoadRetryTimers.current.delete(threadId);
        sessionLoadStates.current.set(threadId, "loaded");
      }

      const replaceSuperseded = !isOlderPage &&
        requestedAtRunSeq !== undefined &&
        (runSeqRef.current[threadId] ?? 0) !== requestedAtRunSeq;
      if (replaceSuperseded) {
        updateHistoryPage(threadId, (previous) => ({
          ...previous, reading: false, loadingOlder: false,
        }));
        return;
      }

      setMessagesMap((prev) => {
        const incoming = data.messages as ThreadMessageLike[];
        let updated: ThreadMessageLike[];
        if (data.prepend === true) {
          const seen = new Set((prev[threadId] ?? []).map((message) => message.id));
          const older: ThreadMessageLike[] = [];
          for (const message of incoming) {
            if (seen.has(message.id)) continue;
            seen.add(message.id);
            older.push(message);
          }
          updated = [...older, ...(prev[threadId] ?? [])];
        } else {
          updated = incoming;
        }
        if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, threadId, updated);
        return { ...prev, [threadId]: updated };
      });

      updateHistoryPage(threadId, () => ({
        reading: false,
        hasMore: data.hasMore === true,
        cursor: data.cursor ?? null,
        loadingOlder: false,
      }));
    });

    // :sessions handler 已注册，通知 R 可以补发 sessions（解决 React 18 异步 render 时序问题）
    bridge.current.sendReady();
    // 预热当前(初始)线程:让 R 后台连接该线程的 client,使首条消息不再冷启动。
    // R 侧仅在 prewarm=TRUE 且 handler 暴露 warmup 时响应(ellmer 等无 warmup → no-op)。
    bridge.current.sendWarmup(
      currentThreadIdRef.current,
      projectForThreadId(currentThreadIdRef.current),
    );
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    requestIdeContextFor(currentThreadId);
  }, [currentThreadId, requestIdeContextFor]);

  // ── 启动一次 streaming run（onNew 和 onReload 共用）────────────────────────
  const startRun = useCallback(
    (threadId: string, sendFn: (runId: string) => void) => {
      // Final safety net: one backend run per thread. Callers that can be
      // deferred (service/clock paths) check and requeue before reaching here.
      if (activeRunsRef.current.has(threadId)) return false;
      setThreadRunning(threadId, true);
      if (usesRunStateProtocol) setThreadRunPhase(threadId, "connecting", "submitting");
      setSuggestionsMap((previous) => ({ ...previous, [threadId]: [] }));
      streamingIdsRef.current[threadId] = null;

      // 登记本 run：active 集合用于多 tab 同步保护；run 序号和 ID 用于拒绝
      // 同线程旧后端 terminal，避免它提前推进 service FIFO 或结束新任务。
      activeRunsRef.current.add(threadId);
      delete completedRunIdsRef.current[threadId];
      const mySeq = (runSeqRef.current[threadId] ?? 0) + 1;
      runSeqRef.current[threadId] = mySeq;
      const runId = `run-${Date.now()}-${threadId}-${mySeq}`;
      activeTaskRunIdsRef.current[threadId] = runId;
      clearLatestTaskActivity(threadId);
      const isLatestRun = () => runSeqRef.current[threadId] === mySeq;

      bridge.current.setRunCallbacks(threadId, {
        onThinking: (thinkingText) => {
          // Reasoning part stored INLINE in the same assistant message as text
          if (!streamingIdsRef.current[threadId]) {
            streamingIdsRef.current[threadId] = `assistant-${Date.now()}`;
          }
          const msgId = streamingIdsRef.current[threadId];
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const existing = threadMsgs.find((m) => m.id === msgId);
            if (!existing) {
              return {
                ...prev,
                [threadId]: [
                  ...threadMsgs,
                  { id: msgId, role: "assistant" as const, content: [{ type: "reasoning" as const, text: thinkingText }] },
                ],
              };
            }
            // Append to reasoning part
            return {
              ...prev,
              [threadId]: threadMsgs.map((m): ThreadMessageLike => {
                if (m.id !== msgId) return m;
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                const content = [...(m.content as any[])];
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                const ridx = content.findIndex((p: any) => p.type === "reasoning");
                if (ridx < 0) return m;
                const updated = [...content];
                updated[ridx] = { ...content[ridx], text: content[ridx].text + thinkingText };
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                return { ...m, content: updated } as any;
              }),
            };
          });
        },
        onChunk: (chunkText) => {
          // 在调用 setMessagesMap 前先快照 ID——updater 是异步调度的，若
          // onDone 先于 updater 执行会把 streamingIdsRef.current[threadId] 清为 null，
          // 导致 updater 误判为新消息，产生"末尾碎片"分裂 bubble 的 bug。
          if (!streamingIdsRef.current[threadId]) {
            streamingIdsRef.current[threadId] = `assistant-${Date.now()}`;
          }
          const msgId = streamingIdsRef.current[threadId];
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const existing = threadMsgs.find((m) => m.id === msgId);
            let updated: ThreadMessageLike[];
            if (!existing) {
              updated = [
                ...threadMsgs,
                { id: msgId, role: "assistant", content: [{ type: "text", text: chunkText }] },
              ];
            } else {
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              const content = existing.content as any[];
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              const tidx = content.findIndex((p: any) => p.type === "text");
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              const newContent: any[] = tidx >= 0
                ? content.map((p: { type: string; text: string }, i: number) => i === tidx ? { ...p, text: p.text + chunkText } : p)
                : [...content, { type: "text", text: chunkText }];
              updated = threadMsgs.map((m): ThreadMessageLike =>
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                m.id === msgId ? ({ ...m, content: newContent } as any) : m
              );
            }
            // 流式过程中不写 localStorage——每个 token 都序列化是主要卡顿来源；
            // onDone 时统一持久化即可。
            return { ...prev, [threadId]: updated };
          });
        },
        onToolCallStart: (toolCallId, toolName, annotations) => {
          // 流式工具参数：先建空壳 tool-call part，后续 onToolCallDelta 逐字追加 argsText
          const startedAt = Date.now();
          streamingIdsRef.current[threadId] = null;
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            if (threadMsgs.find((m) => m.id === `tool-${toolCallId}`)) return prev;
            const updated: ThreadMessageLike[] = [
              ...threadMsgs,
              {
                id: `tool-${toolCallId}`,
                role: "assistant" as const,
                content: [
                  {
                    type: "tool-call" as const,
                    toolCallId,
                    toolName,
                    // eslint-disable-next-line @typescript-eslint/no-explicit-any
                    args: {} as any,
                    argsText: "",
                    timing: { startedAt },
                    artifact: { ...(annotations ?? {}), argsStreaming: true },
                  },
                ],
              },
            ];
            // 流式期间不写 localStorage（仿 onChunk），避免半截参数腐败历史
            return { ...prev, [threadId]: updated };
          });
        },
        onToolCallDelta: (toolCallId, delta) => {
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const updated = threadMsgs.map((m): ThreadMessageLike => {
              if (m.id !== `tool-${toolCallId}`) return m;
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              const content = m.content as any[];
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              const cidx = content.findIndex((p: any) => p.type === "tool-call");
              if (cidx < 0) return m;
              const newContent = [...content];
              const argsText = (content[cidx].argsText ?? "") + delta;
              const provisionalArgs = content[cidx].toolName === "Write"
                ? projectPartialWriteArgs(argsText)
                : {};
              newContent[cidx] = {
                ...content[cidx],
                argsText,
                args: content[cidx].toolName === "Write"
                  ? { ...(content[cidx].args ?? {}), ...provisionalArgs }
                  : content[cidx].args,
              };
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              return { ...m, content: newContent } as any;
            });
            return { ...prev, [threadId]: updated };
          });
        },
        onToolCall: (toolCall) => {
          const startedAt = Date.now();
          streamingIdsRef.current[threadId] = null;
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const existing = threadMsgs.find((m) => m.id === `tool-${toolCall.toolCallId}`);
            let updated: ThreadMessageLike[];
            if (existing) {
              // 已被 onToolCallStart 创建（Claude 流式路径）：补全解析后的 args + artifact，不重复 push
              updated = threadMsgs.map((m): ThreadMessageLike => {
                if (m.id !== `tool-${toolCall.toolCallId}`) return m;
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                const content = m.content as any[];
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                const cidx = content.findIndex((p: any) => p.type === "tool-call");
                if (cidx < 0) return m;
                const newContent = [...content];
                newContent[cidx] = {
                  ...content[cidx],
                  // eslint-disable-next-line @typescript-eslint/no-explicit-any
                  args: toolCall.args as any,
                  argsText: toolCall.argsText,
                  timing: content[cidx].timing ?? { startedAt },
                  artifact: {
                    ...(content[cidx].artifact && typeof content[cidx].artifact === "object"
                      ? content[cidx].artifact
                      : {}),
                    ...(toolCall.annotations ?? {}),
                    argsStreaming: false,
                  },
                };
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                return { ...m, content: newContent } as any;
              });
            } else {
              // 无 start（ellmer 路径）：整包新建
              updated = [
                ...threadMsgs,
                {
                  id: `tool-${toolCall.toolCallId}`,
                  role: "assistant" as const,
                  content: [
                    {
                      type: "tool-call" as const,
                      toolCallId: toolCall.toolCallId,
                      toolName: toolCall.toolName,
                      // eslint-disable-next-line @typescript-eslint/no-explicit-any
                      args: toolCall.args as any,
                      argsText: toolCall.argsText,
                      timing: { startedAt },
                      artifact: { ...(toolCall.annotations ?? {}), argsStreaming: false },
                    },
                  ],
                },
              ];
            }
            if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, threadId, updated);
            return { ...prev, [threadId]: updated };
          });
        },
        onToolResult: (toolCallId, result, isError) => {
          const completedAt = Date.now();
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const updated = threadMsgs.map((m): ThreadMessageLike => {
              // 按 type + toolCallId 定位 part（不假设 content[0]），与
              // markStaleToolCalls / onToolCallDelta 保持一致，兼容未来多 part 消息。
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              const content = m.content as any[];
              if (!Array.isArray(content)) return m;
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              const cidx = content.findIndex(
                (p: any) => p?.type === "tool-call" && p.toolCallId === toolCallId,
              );
              if (cidx < 0) return m;
              const newContent = [...content];
              newContent[cidx] = {
                ...content[cidx],
                timing: {
                  startedAt: content[cidx].timing?.startedAt ?? completedAt,
                  completedAt,
                },
                artifact: {
                  ...(content[cidx].artifact && typeof content[cidx].artifact === "object"
                    ? content[cidx].artifact
                    : {}),
                  argsStreaming: false,
                },
                result,
                isError,
              };
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              return { ...m, content: newContent } as any;
            });
            if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, threadId, updated);
            return { ...prev, [threadId]: updated };
          });
        },
        onSource: (source) => {
          if (!streamingIdsRef.current[threadId]) streamingIdsRef.current[threadId] = `assistant-${Date.now()}`;
          const msgId = streamingIdsRef.current[threadId];
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          const part: any = {
            type: "source", sourceType: "url",
            id: source.id ?? `src-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
            url: source.url, title: source.title ?? source.url,
          };
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const existing = threadMsgs.find((m) => m.id === msgId);
            const updated = existing
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              ? threadMsgs.map((m): ThreadMessageLike => m.id === msgId ? ({ ...m, content: [...(m.content as any[]), part] } as any) : m)
              : [...threadMsgs, { id: msgId, role: "assistant" as const, content: [part] }];
            if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, threadId, updated);
            return { ...prev, [threadId]: updated };
          });
        },
        onImage: (image) => {
          if (!streamingIdsRef.current[threadId]) streamingIdsRef.current[threadId] = `assistant-${Date.now()}`;
          const msgId = streamingIdsRef.current[threadId];
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          const part: any = { type: "image", image };
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const existing = threadMsgs.find((m) => m.id === msgId);
            const updated = existing
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              ? threadMsgs.map((m): ThreadMessageLike => m.id === msgId ? ({ ...m, content: [...(m.content as any[]), part] } as any) : m)
              : [...threadMsgs, { id: msgId, role: "assistant" as const, content: [part] }];
            if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, threadId, updated);
            return { ...prev, [threadId]: updated };
          });
        },
        onData: ({ name, data }) => {
          // Plan 47 A0 — append a `data-<name>` part; ThreadMessageLike auto-converts it to
          // {type:"data", name, data}, which thread.tsx's case "data" → renderDataPart renders.
          if (!streamingIdsRef.current[threadId]) streamingIdsRef.current[threadId] = `assistant-${Date.now()}`;
          const msgId = streamingIdsRef.current[threadId];
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          const part: any = { type: `data-${name}`, data };
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const existing = threadMsgs.find((m) => m.id === msgId);
            const updated = existing
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              ? threadMsgs.map((m): ThreadMessageLike => m.id === msgId ? ({ ...m, content: [...(m.content as any[]), part] } as any) : m)
              : [...threadMsgs, { id: msgId, role: "assistant" as const, content: [part] }];
            if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, threadId, updated);
            return { ...prev, [threadId]: updated };
          });
        },
        onGenerativeUi: ({ spec }) => {
          // Plan 47 A1 — append a `generative-ui` part; thread.tsx case "generative-ui" renders
          // it via MessagePrimitive.GenerativeUI + shinyAllowlist.
          if (!streamingIdsRef.current[threadId]) streamingIdsRef.current[threadId] = `assistant-${Date.now()}`;
          const msgId = streamingIdsRef.current[threadId];
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          const part: any = { type: "generative-ui", spec };
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const existing = threadMsgs.find((m) => m.id === msgId);
            const updated = existing
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              ? threadMsgs.map((m): ThreadMessageLike => m.id === msgId ? ({ ...m, content: [...(m.content as any[]), part] } as any) : m)
              : [...threadMsgs, { id: msgId, role: "assistant" as const, content: [part] }];
            if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, threadId, updated);
            return { ...prev, [threadId]: updated };
          });
        },
        onArtifact: (artifact) => {
          if (deletedThreadIdsRef.current.has(threadId)) return;
          setArtifactsMap((previous) => {
            const owned = previous[threadId] ?? [];
            const idx = owned.findIndex((item) => item.id === artifact.id);
            const next = [...owned];
            if (idx >= 0) next[idx] = artifact;
            else next.push(artifact);
            return { ...previous, [threadId]: next };
          });
          setActiveArtifactIds((previous) => ({ ...previous, [threadId]: artifact.id }));
        },
        onAutoContinue: (data) => {
          if (data.runId && data.runId !== runId) return;
          const recoveryId = data.runId ?? runId;
          if (autoContinueRunIdsRef.current.has(recoveryId)) return;
          autoContinueRunIdsRef.current.add(recoveryId);
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const updated: ThreadMessageLike[] = [
              ...threadMsgs,
              {
                id: `auto-continue-notice-${recoveryId}`,
                role: "assistant" as const,
                content: [{ type: "text" as const, text: `⚠ ${data.notice}` }],
              },
            ];
            if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, threadId, updated);
            return { ...prev, [threadId]: updated };
          });
          const queued = messageQueueRef.current.get(threadId) ?? [];
          queued.unshift({
            text: data.prompt,
            sendText: data.prompt,
            project: projectForThreadId(threadId),
            continuationKind: data.kind,
          });
          messageQueueRef.current.set(threadId, queued);
        },
        onDone: (doneSuggestions, incomingRunId, cancelled = false) => {
          if (incomingRunId && incomingRunId !== runId) return;
          streamingIdsRef.current[threadId] = null;
          // 只有当前 thread 仍是发起此 run 的 thread 时才清 running 状态
          // 避免用户切换 thread 后旧 handler 的 onDone 把新 thread 的 running 错误清掉
          setStatusTextMap((previous) => ({ ...previous, [threadId]: null }));
          if (!cancelled && doneSuggestions && doneSuggestions.length > 0) {
            setSuggestionsMap((previous) => ({ ...previous, [threadId]: doneSuggestions }));
          }
          if (usesRunStateProtocol) setThreadRunPhase(threadId, cancelled ? "cancelled" : "complete");
          // 仅当本 run 仍是该线程最新 run 时才注销 callbacks / 清 active 标记。
          // 避免 run 重入（edit 后立即 reload 等）时旧 run 的 onDone 误删新 run 的 callbacks。
          if (isLatestRun()) {
            activeRunsRef.current.delete(threadId);
            if (cancelled) delete completedRunIdsRef.current[threadId];
            else completedRunIdsRef.current[threadId] = runId;
            delete activeTaskRunIdsRef.current[threadId];
            clearLatestTaskActivity(threadId);
            setThreadRunning(threadId, false);
            bridge.current.retireRunCallbacks(threadId);
          }
          advancePendingSubmissionsRef.current(threadId, runId, true);
          setMessagesMap((prev) => {
            // 收口：把任何未完成的 tool-call part 标记中断。正常结束时无半截卡
            // （changed=false，零影响）；中断 drain 时 R 可能漏发 on_tool_result，
            // 此处兜底避免卡片永久转圈。
            const { messages: msgs, changed } = markStaleToolCalls(
              prev[threadId] ?? [],
              "Interrupted",
            );
            if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, threadId, msgs);
            return changed ? { ...prev, [threadId]: msgs } : { ...prev, [threadId]: prev[threadId] ?? [] };
          });
          const pendingReplacement = proactiveAfterRunRef.current.get(threadId);
          if (pendingReplacement?.afterRunId === runId) {
            proactiveAfterRunRef.current.delete(threadId);
            if (!cancelled && isLatestRun()) {
              proactiveRevisionsRef.current.set(threadId, pendingReplacement.revision);
              commitProactiveReplacement(pendingReplacement);
            }
          }
        },
        onError: (errMsg, incomingRunId) => {
          if (incomingRunId && incomingRunId !== runId) return;
          streamingIdsRef.current[threadId] = null;
          setStatusTextMap((previous) => ({ ...previous, [threadId]: null }));
          if (usesRunStateProtocol) setThreadRunPhase(threadId, "error");
          if (isLatestRun()) {
            activeRunsRef.current.delete(threadId);
            delete activeTaskRunIdsRef.current[threadId];
            clearLatestTaskActivity(threadId);
            setThreadRunning(threadId, false);
            bridge.current.retireRunCallbacks(threadId);
          }
          advancePendingSubmissionsRef.current(threadId, runId, false);
          if (proactiveAfterRunRef.current.get(threadId)?.afterRunId === runId) {
            proactiveAfterRunRef.current.delete(threadId);
          }
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const { messages: settled } = markStaleToolCalls(threadMsgs, "Interrupted");
            const updated = [
              ...settled,
              {
                id: `error-${Date.now()}`,
                role: "assistant" as const,
                content: [{ type: "text" as const, text: `⚠ Error: ${errMsg}` }],
              },
            ];
            if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, threadId, updated);
            return { ...prev, [threadId]: updated };
          });
        },
      });

      sendFn(runId);
      return true;
    },
    [inputId] // eslint-disable-line react-hooks/exhaustive-deps
  );

  const dispatchPendingSubmission = useCallback((submission: PendingSubmission) => {
    return startRun(submission.threadId, (runId) => {
      const inFlight = deferredSubmissionInFlightRef.current.get(submission.threadId);
      if (inFlight?.id === submission.id) inFlight.runId = runId;
      bridge.current.sendUserMessage(
        submission.sendText,
        submission.threadId,
        submission.attachmentData.length > 0 ? submission.attachmentData : undefined,
        capabilityContract.ide ? { selectionVisible: submission.selectionVisible } : undefined,
        submission.quote,
        runId,
        submission.id,
        submission.project,
        submission.continuationKind,
      );
    });
  }, [startRun, capabilityContract.ide]);

  const drainPendingSubmissions = useCallback(() => {
    let changed = false;
    for (let index = 0; index < pendingSubmissionsRef.current.length;) {
      const submission = pendingSubmissionsRef.current[index];
      if (submission.requiresService && serviceStateRef.current?.status !== "ready") {
        index += 1;
        continue;
      }
      if (deferredSubmissionInFlightRef.current.has(submission.threadId) ||
          activeRunsRef.current.has(submission.threadId)) {
        index += 1;
        continue;
      }

      pendingSubmissionsRef.current.splice(index, 1);
      deferredSubmissionInFlightRef.current.set(
        submission.threadId,
        { id: submission.id },
      );
      if (!dispatchPendingSubmission(submission)) {
        deferredSubmissionInFlightRef.current.delete(submission.threadId);
        pendingSubmissionsRef.current.splice(index, 0, submission);
        index += 1;
      } else {
        changed = true;
      }
    }
    if (changed) setPendingSubmissions(pendingSubmissionsRef.current.length);
  }, [dispatchPendingSubmission]);
  drainPendingSubmissionsRef.current = drainPendingSubmissions;
  useEffect(() => {
    if (serviceState?.status === "ready") drainPendingSubmissions();
  }, [serviceState?.status, drainPendingSubmissions]);

  const advancePendingSubmissions = useCallback((threadId: string, runId: string, flushMessages: boolean) => {
    const inFlight = deferredSubmissionInFlightRef.current.get(threadId);
    if (inFlight) {
      if (inFlight.runId !== runId) return;
      deferredSubmissionInFlightRef.current.delete(threadId);
    }
    const queued = messageQueueRef.current.get(threadId);
    const nextIsRecovery = flushMessages && Boolean(queued?.[0]?.continuationKind);
    if (nextIsRecovery) {
      const nextMessage = queued!.shift()!;
      setTimeout(() => {
        const hasInFlight = deferredSubmissionInFlightRef.current.has(threadId);
        if (activeRunsRef.current.has(threadId) || hasInFlight) {
          const latest = messageQueueRef.current.get(threadId) ?? [];
          latest.unshift(nextMessage);
          messageQueueRef.current.set(threadId, latest);
          return;
        }
        deliverTextRef.current?.(
          nextMessage.text,
          threadId,
          nextMessage.project,
          nextMessage.sendText,
          nextMessage.continuationKind,
        );
      }, 40);
      return;
    }
    // A terminal only releases this thread. The drain may concurrently start
    // eligible work for other threads while preserving each thread's FIFO.
    if (pendingSubmissionsRef.current.length > 0) {
      queueMicrotask(() => drainPendingSubmissionsRef.current());
    }
    if (pendingSubmissionsRef.current.some((item) => item.threadId === threadId)) return;
    if (!flushMessages || !queued || queued.length === 0) return;
    const nextMessage = queued.shift()!;
    setTimeout(() => {
      const serviceBusy = deferredSubmissionInFlightRef.current.has(threadId) ||
        pendingSubmissionsRef.current.some((item) => item.threadId === threadId);
      if (activeRunsRef.current.has(threadId) || serviceBusy) {
        const latest = messageQueueRef.current.get(threadId) ?? [];
        latest.unshift(nextMessage);
        messageQueueRef.current.set(threadId, latest);
        return;
      }
      deliverTextRef.current?.(
        nextMessage.text,
        threadId,
        nextMessage.project,
        nextMessage.sendText,
        nextMessage.continuationKind,
      );
    }, 40);
  }, []);
  advancePendingSubmissionsRef.current = advancePendingSubmissions;

  // ── onNew ────────────────────────────────────────────────────────────────
  const onNew = useCallback(
    async (msg: AppendMessage) => {
      if (blockingActionsRef.current[currentThreadId]) return;
      composerDraftsRef.current.delete(currentThreadId);
      // 气泡显示用原始文本（含 /commandName chip 序列化结果）
      const text = msg.content
        .filter((c): c is { type: "text"; text: string } => c.type === "text")
        .map((c) => c.text)
        .join("");

      const slashAction = matchSlashAction(text, actionItems);
      if (slashAction) {
        if (slashAction.id === "model") { setModelPickerOpen(true); return; }
        invokeActionRef.current?.(slashAction);
        return;
      }

      setSubmissionRevision((revision) => revision + 1);

      // 发给 R 的文本：把 /commandName → cmd.prompt 展开
      // （chip directiveText = "/commandName"，R 需要收到实际 prompt）
      const sendText = expandSlashCommands(text, commands);

      const threadId = currentThreadId;
      const project = projectForThreadId(threadId);

      // 第一条消息自动命名线程（在任何 updater 外直接读当前 state）
      const isFirstMsg = (messagesMap[threadId] ?? []).length === 0;
      if (isFirstMsg && !manualTitleIds.current.has(threadId)) {
        const title = text.slice(0, 20) + (text.length > 20 ? "…" : "");
        setThreads((ts) => {
          const next = ts.map((t) => (t.id === threadId ? { ...t, title } : t));
          saveThreads(inputId, usesClientPersistence, next);
          return next;
        });
      }

      // 提取附件：序列化为结构化数据供 R 端使用
      const { attachmentData, storedAttachments } = extractAttachments(msg);

      // 划词引用:发送时 runtime 自动把 quote 写到 msg.metadata.custom.quote({text,messageId})。
      // 带给 R(server.R 前置成 blockquote 注入 prompt)+ 回显在用户气泡。
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const quote = (msg as any).metadata?.custom?.quote as { text: string; messageId: string } | undefined;

      // 追加用户消息。若服务等待稍后被用户取消，此稳定 id 用于同时
      // 回滚未发送气泡，避免 UI 历史领先于后端 Claude session。
      const userMessageId = `user-${Date.now()}-${++messageIdSeq.current}`;
      setCurrentMessages((prev) => [
        ...prev,
        {
          id: userMessageId,
          role: "user" as const,
          content: [{ type: "text" as const, text }],
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          ...(storedAttachments.length > 0 && { attachments: storedAttachments } as any),
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          ...(quote && ({ metadata: { custom: { quote } } } as any)),
        },
      ]);

      const waitingForService = serviceStateRef.current !== undefined &&
        (serviceStateRef.current.status === "checking" ||
         serviceStateRef.current.status === "starting" ||
         serviceStateRef.current.status === "failed");
      const threadHasQueuedWork = deferredSubmissionInFlightRef.current.has(threadId) ||
        pendingSubmissionsRef.current.some((item) => item.threadId === threadId);
      const mustDefer = waitingForService || activeRunsRef.current.has(threadId) || threadHasQueuedWork;
      if (mustDefer) {
        const submissionId = `service-submission-${Date.now()}-${++deferredSubmissionSeq.current}`;
        pendingSubmissionsRef.current.push({
          id: submissionId,
          requiresService: waitingForService,
          userMessageId,
          threadId,
          displayText: text,
          sendText,
          attachmentData,
          storedAttachments,
          quote,
          selectionVisible: selectionVisibleRef.current,
          project,
          original: msg,
        });
        if (capabilityContract.ide) {
          bridge.current.reserveIdeContext(submissionId, threadId, selectionVisibleRef.current, project);
        }
        setPendingSubmissions(pendingSubmissionsRef.current.length);
        return;
      }

      startRun(threadId, (runId) => {
        requestIdeContextFor(threadId);
        bridge.current.sendUserMessage(
          sendText, threadId,
          attachmentData.length > 0 ? attachmentData : undefined,
          capabilityContract.ide ? { selectionVisible: selectionVisibleRef.current } : undefined,
          quote,
          runId,
          undefined,
          project,
        );
      });
    },
    [inputId, currentThreadId, setCurrentMessages, messagesMap, commands, actionItems, startRun]
  );

  // ── 消息队列:文本-only 投递(队列 flush 用)+ 入队 ─────────────────────────────
  // deliverText 追加用户气泡到指定线程并 startRun 发送(无附件)。存入 ref 供 onDone
  // flush 调用(避免 startRun 闭包对后定义函数的时序依赖)。
  const deliverText = useCallback((
    text: string,
    threadId: string,
    projectSnapshot?: string,
    sendTextSnapshot?: string,
    continuationKind?: AutoContinueKind,
  ) => {
    if (!text.trim() || blockingActionsRef.current[threadId]) return;
    const project = workspaceMode
      ? projectSnapshot || projectForThreadId(threadId)
      : undefined;
    const sendText = sendTextSnapshot ?? expandSlashCommands(text, commands);
    const hasInFlight = deferredSubmissionInFlightRef.current.has(threadId);
    const hasPending = pendingSubmissionsRef.current.some((item) => item.threadId === threadId);
    const recovery = continuationKind !== undefined;
    if (activeRunsRef.current.has(threadId) || hasInFlight || (!recovery && hasPending)) {
      const queued = messageQueueRef.current.get(threadId) ?? [];
      const item = { text, sendText, project, continuationKind };
      if (recovery) queued.unshift(item); else queued.push(item);
      messageQueueRef.current.set(threadId, queued);
      return;
    }
    const slashAction = matchSlashAction(text, actionItems);
    if (slashAction) {
      if (slashAction.id === "model") { setModelPickerOpen(true); return; }
      invokeActionRef.current?.(slashAction);
      return;
    }
    const userMessageId = `user-${Date.now()}-${++messageIdSeq.current}`;
    setMessagesMap((prev) => {
      const threadMsgs = prev[threadId] ?? [];
      const updated: ThreadMessageLike[] = [
        ...threadMsgs,
        { id: userMessageId, role: "user" as const, content: [{ type: "text" as const, text }] },
      ];
      if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, threadId, updated);
      return { ...prev, [threadId]: updated };
    });
    const serviceBlocked = serviceStateRef.current !== undefined &&
      ["checking", "starting", "failed"].includes(serviceStateRef.current.status);
    if (serviceBlocked) {
      const submissionId = `service-submission-${Date.now()}-${++deferredSubmissionSeq.current}`;
      const submission: PendingSubmission = {
        id: submissionId,
        requiresService: true,
        userMessageId,
        threadId,
        displayText: text,
        sendText,
        attachmentData: [],
        storedAttachments: [],
        selectionVisible: selectionVisibleRef.current,
        project,
        continuationKind,
      };
      if (recovery) pendingSubmissionsRef.current.unshift(submission);
      else pendingSubmissionsRef.current.push(submission);
      if (capabilityContract.ide) {
        bridge.current.reserveIdeContext(submissionId, threadId, selectionVisibleRef.current, project);
      }
      setPendingSubmissions(pendingSubmissionsRef.current.length);
      return;
    }
    startRun(threadId, (runId) => {
      requestIdeContextFor(threadId);
      bridge.current.sendUserMessage(
        sendText, threadId, undefined,
        capabilityContract.ide ? { selectionVisible: selectionVisibleRef.current } : undefined,
        undefined,
        runId,
        undefined,
        project,
        continuationKind,
      );
    });
  }, [inputId, commands, actionItems, startRun, requestIdeContextFor, capabilityContract.ide, workspaceMode, projectForThreadId]);
  deliverTextRef.current = deliverText;

  // 入队:AI 运行中时把消息排队,当前 run 结束后自动发送(见 onDone flush)。
  const enqueueMessage = useCallback((text: string) => {
    if (!text.trim()) return;
    const tid = currentThreadIdRef.current;
    const q = messageQueueRef.current.get(tid) ?? [];
    q.push({
      text,
      sendText: expandSlashCommands(text, commands),
      project: projectForThreadId(tid),
    });
    messageQueueRef.current.set(tid, q);
  }, [commands, projectForThreadId]);

  // ── invokeAction:客户端动作(如 /model /clear),不发给 AI ────────────────────
  // 在对话里记录一条"用户操作"气泡 + 一条系统确认(ack)气泡,并把 action id 发给 R
  // (on_action 执行真实操作,如切模型 / 清历史)。绝不触发 AI run。
  const invokeAction = useCallback((item: ActionItemDef) => {
    const threadId = currentThreadIdRef.current;
    if (blockingActionsRef.current[threadId]) return;
    const label = item.label ?? item.id;
    const command = item.command ?? item.id;
    const requestId = makeActionRequestId();
    const ackId = `ack-${requestId}`;
    const compactStartedAt = item.id === "compact" ? Date.now() : undefined;
    const compactData: CompactActionProgress | undefined = compactStartedAt === undefined
      ? undefined
      : {
          kind: "compact",
          phase: "starting",
          startedAt: compactStartedAt,
          message: "Preparing conversation\u2026",
        };
    setMessagesMap((prev) => {
      const msgs = prev[threadId] ?? [];
      const updated: ThreadMessageLike[] = [
        ...msgs,
        { id: `user-${requestId}`, role: "user" as const,
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          content: [{ type: "text" as const, text: `/${command}` }], metadata: { custom: { shinyAction: true } } as any },
        { id: ackId, role: "assistant" as const,
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          content: compactData
            ? ([{ type: "data-action-progress", data: compactData }] as any)
            : [{ type: "text" as const, text: `\u2699\ufe0f ${label}\u2026` }],
          metadata: { custom: { shinyActionAck: true } } as any },
      ];
      if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, threadId, updated);
      return { ...prev, [threadId]: updated };
    });
    if (compactData) setBlockingActionForThread(threadId, compactData as BlockingAction);
    const target: {
      threadId: string;
      ackId: string;
      actionId: string;
      startedAt?: number;
      timeoutId?: number;
    } = { threadId, ackId, actionId: item.id, startedAt: compactStartedAt };
    if (compactData) {
      target.timeoutId = window.setTimeout(() => {
        if (actionAckRefs.current.get(requestId) !== target) return;
        const data: CompactActionProgress = {
          kind: "compact",
          phase: "error",
          startedAt: compactData.startedAt,
          message: "Compaction interrupted: no terminal response",
        };
        setMessagesMap((prev) => {
          const msgs = prev[threadId] ?? [];
          const updated = msgs.map((m): ThreadMessageLike =>
            m.id === ackId
              ? ({ ...m, content: [{ type: "data-action-progress", data }] } as any)
              : m,
          );
          if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, threadId, updated);
          return { ...prev, [threadId]: updated };
        });
        setBlockingActionForThread(threadId);
        actionAckRefs.current.delete(requestId);
      }, COMPACT_CLIENT_TIMEOUT_MS);
    }
    actionAckRefs.current.set(requestId, target);
    bridge.current.sendAction(
      item.id,
      threadId,
      { requestId },
      projectForThreadId(threadId),
    );
  }, [inputId, setBlockingActionForThread]);
  invokeActionRef.current = invokeAction;

  // ── onEdit ───────────────────────────────────────────────────────────────
  // parentId = 被编辑 user 消息的前一条消息 ID；截断到 parentId，重新插入编辑后的
  // user 消息并重发。必须重新插入——外部存储模式下框架不持有消息，messagesMap 是
  // 唯一真相源，只截断不插入会导致编辑后的 user 气泡从界面消失。
  const onEdit = useCallback(
    async (message: AppendMessage) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const text = (message.content as any[])
        .filter((p: { type: string }) => p.type === "text")
        .map((p: { text: string }) => p.text)
        .join("");
      if (!text.trim()) return;
      const threadId = currentThreadIdRef.current;
      if (blockingActionsRef.current[threadId]) return;
      const serviceBlocked = serviceStateRef.current !== undefined &&
        ["checking", "starting", "failed"].includes(serviceStateRef.current.status);
      const serviceBusy = deferredSubmissionInFlightRef.current.has(threadId) ||
        pendingSubmissionsRef.current.some((item) => item.threadId === threadId);
      if (serviceBlocked || serviceBusy || activeRunsRef.current.has(threadId)) return;
      const parentId = message.parentId ?? null;
      const { attachmentData, storedAttachments } = extractAttachments(message);

      // slash 命令展开（与 onNew 一致）
      const sendText = expandSlashCommands(text, commands);

      // 标志：parentId 陈旧找不到时跳过本次编辑（连 startRun 一起跳过，
      // 避免只发消息给 R 却不插 user 气泡，导致孤儿 assistant 回复 + UI/R 发散）。
      const newUserMessage: ThreadMessageLike = {
        id: `user-${Date.now()}-${++messageIdSeq.current}`,
        role: "user" as const,
        content: [{ type: "text" as const, text }],
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        ...(storedAttachments.length > 0 && { attachments: storedAttachments } as any),
      };
      setMessagesMap((prev) => {
        const threadMsgs = prev[threadId] ?? [];
        const updated = applyEdit(threadMsgs, parentId, newUserMessage);
        if (usesClientPersistence) saveMessages(inputId, usesClientPersistence, threadId, updated);
        return { ...prev, [threadId]: updated };
      });
      startRun(threadId, (runId) => {
        requestIdeContextFor(threadId);
        bridge.current.sendUserMessage(
          sendText, threadId,
          attachmentData.length > 0 ? attachmentData : undefined,
          capabilityContract.ide ? { selectionVisible: selectionVisibleRef.current } : undefined,
          undefined,
          runId,
          undefined,
          projectForThreadId(threadId),
        );
      });
    },
    [inputId, startRun, commands, projectForThreadId] // eslint-disable-line react-hooks/exhaustive-deps
  );

  // ── onReload ─────────────────────────────────────────────────────────────  // parentId = 触发本次 assistant 回复的 user 消息 ID
  const onReload = useCallback(
    async (parentId: string | null, _config: StartRunConfig) => {
      const threadId = currentThreadId;
      if (blockingActionsRef.current[threadId]) return;
      const serviceBlocked = serviceStateRef.current !== undefined &&
        ["checking", "starting", "failed"].includes(serviceStateRef.current.status);
      const serviceBusy = deferredSubmissionInFlightRef.current.has(threadId) ||
        pendingSubmissionsRef.current.some((item) => item.threadId === threadId);
      if (serviceBlocked || serviceBusy || activeRunsRef.current.has(threadId)) return;
      const msgs = messagesMap[threadId] ?? [];

      // 找到 parent user 消息的文本
      const parentMsg = parentId ? msgs.find((m) => m.id === parentId) : null;
      const rawContent = parentMsg?.content;
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const contentArr: any[] = Array.isArray(rawContent) ? rawContent : [];
      const userText = contentArr
        .filter((c) => c?.type === "text")
        .map((c) => c.text as string)
        .join("");

      if (!userText) return;

      // 删除 parentId 之后的所有消息（即上一条 assistant 回复）
      setCurrentMessages((prev) => {
        const idx = parentId ? prev.findIndex((m) => m.id === parentId) : -1;
        return idx >= 0 ? prev.slice(0, idx + 1) : prev;
      });

      startRun(threadId, (runId) => bridge.current.sendReload(
        userText,
        threadId,
        runId,
        projectForThreadId(threadId),
      ));
    },
    [currentThreadId, messagesMap, setCurrentMessages, startRun, projectForThreadId]
  );

  // ── onCancel ─────────────────────────────────────────────────────────────
  const onCancel = useCallback(async () => {
    const threadId = currentThreadId;
    // Do NOT null streamingIdRef here — in-flight chunks that arrive before R
    // detects the cancel would create a new message bubble (second AI avatar).
    // Let onDone null it naturally once the stream is fully closed.
    setThreadRunning(threadId, false);
    if (usesRunStateProtocol) setThreadRunPhase(threadId, "cancelled");
    // Do NOT clear callbacks here — R will still send on_tool_result / on_done
    // during drain mode after interrupt. Let onDone clear them naturally.
    bridge.current.sendCancel(threadId, activeTaskRunIdsRef.current[threadId]);
  }, [currentThreadId]);

  // ── new thread creation ──────────────────────────────────────────────────
  // Workspace folder actions pass an explicit project so thread ownership does
  // not depend on whichever workingDir happened to be selected previously.
  const createNewThread = useCallback((projectOverride?: string) => {
    const explicitProject = typeof projectOverride === "string" && projectOverride.length > 0
      ? projectOverride
      : undefined;
    if (workspaceMode && explicitProject) {
      const projectChanged = explicitProject !== workingDirRef.current;
      workingDirRef.current = explicitProject;
      setWorkingDirState(explicitProject);
      setWorkspaceProjectOrder((previous) =>
        previous.includes(explicitProject) ? previous : [explicitProject, ...previous]
      );
      if (projectChanged) bridge.current.sendSetWorkingDir(explicitProject);
    }

    const newId = makeThreadId();
    knownThreadIdsRef.current.add(newId);
    thisSessionThreadIds.current.add(newId);
    const project = workspaceMode
      ? explicitProject ?? (workingDirRef.current || undefined)
      : undefined;
    if (project) threadProjectsRef.current.set(newId, project);
    const newThread: ExternalStoreThreadData<"regular"> = {
      id: newId,
      status: "regular",
      title: "New chat",
      ...(project ? { custom: { project, projectLabel: projectLabel(project) } } : {}),
    };
    setThreads((previous) => {
      const next = [newThread, ...previous];
      saveThreads(inputId, usesClientPersistence, next);
      return next;
    });
    switchCurrentThread(newId);
  }, [inputId, usesClientPersistence, workspaceMode]);

  // Upstream ThreadListPrimitive.New remains parameterless for ordinary Chat.
  const switchToNewThread = useCallback(() => createNewThread(), [createNewThread]);
  const newThreadInProject = useCallback(
    (project: string) => createNewThread(project),
    [createNewThread],
  );

  // ── 线程重命名（rename）──────────────────────────────────────────────────────
  // manualTitleIds：被用户手动改过标题的线程,首条消息自动命名时不再覆盖。
  const renameThread = useCallback((threadId: string, newTitle: string) => {
    const title = newTitle.trim();
    if (!title) return;
    manualTitleIds.current.add(threadId);
    setThreads((prev) => {
      if (!prev.some((t) => t.id === threadId)) return prev;
      const next = prev.map((t) => (t.id === threadId ? { ...t, title } : t));
      saveThreads(inputId, usesClientPersistence, next);
      return next;
    });
    setArchivedThreads((prev) => {
      if (!prev.some((t) => t.id === threadId)) return prev;
      const next = prev.map((t) => (t.id === threadId ? { ...t, title } : t));
      saveArchivedThreads(inputId, usesClientPersistence, next);
      return next;
    });
    bridge.current.sendRename(threadId, title, projectForThreadId(threadId));
  }, [inputId, projectForThreadId]);

  // ── 点击文件引用 → 优先用本线程最近工具调用的精确路径，再请求 IDE 打开 ──────
  const openFile = useCallback((path: string, line?: number) => {
    if (!path) return;
    const threadId = currentThreadIdRef.current;
    bridge.current.sendOpenFile(
      resolveToolFileReference(path, messages),
      line,
      threadId,
      projectForThreadId(threadId),
    );
  }, [messages, projectForThreadId]);
  // 代码块"Run in Console"：在用户活 R 会话执行(addin/RStudio；config.console_run 开启才暴露)。
  const consoleRunEnabled = config?.console_run === true;
  const runInConsole = useCallback((code: string) => {
    if (!code) return;
    const threadId = currentThreadIdRef.current;
    bridge.current.sendRunInConsole(code, threadId, projectForThreadId(threadId));
  }, [projectForThreadId]);

  const clearThreadRuntimeState = useCallback((threadId: string) => {
    const omitThread = <T,>(previous: Record<string, T>): Record<string, T> => {
      if (!(threadId in previous)) return previous;
      const next = { ...previous };
      delete next[threadId];
      return next;
    };

    activeRunsRef.current.delete(threadId);
    delete activeTaskRunIdsRef.current[threadId];
    delete runSeqRef.current[threadId];
    delete streamingIdsRef.current[threadId];
    manualTitleIds.current.delete(threadId);
    bridge.current.setRunCallbacks(threadId, null);
    messageQueueRef.current.delete(threadId);

    const nextPhases = omitThread(runPhaseMapRef.current);
    runPhaseMapRef.current = nextPhases;
    setRunPhaseMap(nextPhases);
    const nextStages = omitThread(runStageMapRef.current);
    runStageMapRef.current = nextStages;
    setRunStageMap(nextStages);
    const nextQueuePositions = omitThread(runQueuePositionMapRef.current);
    runQueuePositionMapRef.current = nextQueuePositions;
    setRunQueuePositionMap(nextQueuePositions);
    setThreadRunning(threadId, false);
    setWarmingThreads((previous) => {
      const next = new Set(previous);
      next.delete(threadId);
      return next;
    });
    setWarmingResumingThreads((previous) => {
      const next = new Set(previous);
      next.delete(threadId);
      return next;
    });

    setMessagesMap((previous) => omitThread(previous));
    setSuggestionsMap((previous) => omitThread(previous));
    setArtifactsMap((previous) => omitThread(previous));
    setActiveArtifactIds((previous) => omitThread(previous));
    setUsageMap((previous) => omitThread(previous));
    setAgentStateMap((previous) => omitThread(previous));
    setRateLimitMap((previous) => omitThread(previous));
    setStatusTextMap((previous) => omitThread(previous));
    setServerCommandsByThread((previous) => omitThread(previous));
    setDismissedChecklistRevisions((previous) => omitThread(previous));
    setLatestTaskActivityIds((previous) => omitThread(previous));
    setPermissionValues((previous) => omitThread(previous));
    setPermissionPending((previous) => omitThread(previous));
    setPermissionErrors((previous) => omitThread(previous));
    setModelValues((previous) => omitThread(previous));
    setModelPending((previous) => omitThread(previous));
    setModelErrors((previous) => omitThread(previous));
    permissionPendingRef.current = omitThread(permissionPendingRef.current);
    modelPendingRef.current = omitThread(modelPendingRef.current);
    setBlockingActionForThread(threadId);

    for (const [requestId, request] of permissionRequestsRef.current) {
      if (request.threadId === threadId) permissionRequestsRef.current.delete(requestId);
    }
    for (const [requestId, request] of modelRequestsRef.current) {
      if (request.threadId === threadId) modelRequestsRef.current.delete(requestId);
    }
    for (const [requestId, action] of actionAckRefs.current) {
      if (action.threadId !== threadId) continue;
      if (action.timeoutId !== undefined) window.clearTimeout(action.timeoutId);
      actionAckRefs.current.delete(requestId);
    }
    if (deferredSubmissionInFlightRef.current.delete(threadId)) {
      queueMicrotask(() => drainPendingSubmissionsRef.current());
    }
  }, [setBlockingActionForThread, setThreadRunning]);

  // ── threadList adapter ───────────────────────────────────────────────────
  const threadListThreads = useMemo(() => threads.map((thread) => {
    const phase = runPhaseMap[thread.id];
    const activePhase = phase === "queued" || phase === "connecting" || phase === "running";
    const custom = { ...(thread.custom ?? {}) };
    if (activePhase) custom.runPhase = phase;
    else delete custom.runPhase;
    if (workspaceMode) {
      const taskCount = selectThreadTaskMonitor(taskMonitorState, thread.id).active.length;
      if (taskCount > 0) custom.activeTaskCount = taskCount;
      else delete custom.activeTaskCount;
    }
    return { ...thread, custom };
  }), [threads, runPhaseMap, taskMonitorState, workspaceMode]);
  const threadListAdapter = useMemo(
    () => ({
      threadId: currentThreadId,
      threads: threadListThreads,
      archivedThreads,
      onSwitchToNewThread: switchToNewThread,
      onSwitchToThread: (threadId: string) => {
        switchCurrentThread(threadId);
        const project = projectForThreadId(threadId);
        if (workspaceMode && project && project !== workingDirRef.current) {
          workingDirRef.current = project;
          setWorkingDirState(project);
          setGitBranch(undefined);
          bridge.current.sendSetWorkingDir(project);
        }
        // 注意：不在切换线程时清空 callbacks——正在运行的流应继续完成
        // Server-backed history may keep growing after its first hydration (for
        // example a background task finishing). Explicitly switching back starts
        // a fresh traversal; loading requests still de-duplicate above.
        if (serverSessionIdsRef.current.has(threadId)) {
          if (proactiveSkipNextHistoryRefreshRef.current.delete(threadId)) {
            sessionLoadStates.current.set(threadId, "loaded");
          } else {
            requestSessionLoad(threadId, true);
          }
        }
      },
      onArchive: (threadId: string) => {
        if (activeRunsRef.current.has(threadId)) {
          bridge.current.sendCancel(threadId, activeTaskRunIdsRef.current[threadId]);
        }
        cancelPendingSubmissions(threadId);
        messageQueueRef.current.delete(threadId);
        setBlockingActionForThread(threadId);
        setThreads((prev) => {
          const target = prev.find((t) => t.id === threadId);
          const next = prev.filter((t) => t.id !== threadId);
          saveThreads(inputId, usesClientPersistence, next);
          if (target) {
            setArchivedThreads((arch) => {
              const nextArch = [
                { ...target, status: "archived" as const },
                ...arch,
              ];
              saveArchivedThreads(inputId, usesClientPersistence, nextArch);
              return nextArch;
            });
          }
          if (threadId === currentThreadId) {
            switchAwayFrom(threadId, prev);
          }
          return next;
        });
        // 方案B：通知服务端持久化软隐藏（可恢复）。
        bridge.current.sendArchiveSession(threadId, true, projectForThreadId(threadId));
      },
      onUnarchive: (threadId: string) => {
        setArchivedThreads((prev) => {
          const target = prev.find((t) => t.id === threadId);
          const next = prev.filter((t) => t.id !== threadId);
          saveArchivedThreads(inputId, usesClientPersistence, next);
          if (target) {
            setThreads((active) => {
              const nextActive = [
                { ...target, status: "regular" as const },
                ...active,
              ];
              saveThreads(inputId, usesClientPersistence, nextActive);
              return nextActive;
            });
          }
          return next;
        });
        bridge.current.sendArchiveSession(threadId, false, projectForThreadId(threadId));
      },
      onDelete: (threadId: string) => {
        if (activeRunsRef.current.has(threadId)) {
          bridge.current.sendCancel(threadId, activeTaskRunIdsRef.current[threadId]);
        }
        deletedThreadIdsRef.current.add(threadId);
        knownThreadIdsRef.current.delete(threadId);
        clearProactiveThreadTracking(threadId);
        composerDraftsRef.current.delete(threadId);
        cancelPendingSubmissions(threadId);
        clearThreadRuntimeState(threadId);
        clearThreadHistoryTracking(threadId);
        const wasServerSession = !thisSessionThreadIds.current.has(threadId);
        // 从活跃或归档列表中删除
        setThreads((prev) => {
          const inActive = prev.some((t) => t.id === threadId);
          if (!inActive) return prev;
          const next = prev.filter((t) => t.id !== threadId);
          saveThreads(inputId, usesClientPersistence, next);
          deleteMessages(inputId, usesClientPersistence, threadId);
          if (threadId === currentThreadId) {

            switchAwayFrom(threadId, prev, false);
          }
          return next;
        });
        setArchivedThreads((prev) => {
          const inArchived = prev.some((t) => t.id === threadId);
          if (!inArchived) return prev;
          const next = prev.filter((t) => t.id !== threadId);
          saveArchivedThreads(inputId, usesClientPersistence, next);
          deleteMessages(inputId, usesClientPersistence, threadId);
          return next;
        });
        // 方案B：server 上真实存在的 session 才通知后端真删磁盘 transcript（不可逆）。
        // 本次新建、从未上传 server 的空白线程只在本地移除。
        if (wasServerSession) {
          bridge.current.sendDeleteSession(threadId, projectForThreadId(threadId));
        }
      },
    }),
    [inputId, currentThreadId, threads, threadListThreads, archivedThreads, switchAwayFrom,
      cancelPendingSubmissions, clearThreadHistoryTracking, clearThreadRuntimeState,
      clearProactiveThreadTracking, setBlockingActionForThread, workspaceMode, projectForThreadId]
  );

  const sendToolApproval = useCallback(
    (toolCallId: string, approved: boolean, opts?: { suggestionIdx?: number; suggestionIdxs?: number[]; customMessage?: string; answers?: Record<string, string | string[]>; updatedInput?: Record<string, unknown> }) => {
      bridge.current.sendToolApproval(toolCallId, approved, opts);
    },
    [] // eslint-disable-line react-hooks/exhaustive-deps
  );

  const setPermissionMode = useCallback((nextValue: string) => {
    if (!permissionCapability || !AVAILABLE_PERMISSION_MODES.has(nextValue)) return;
    const threadId = currentThreadIdRef.current;
    const option = permissionCapability.options.find((item) => item.value === nextValue);
    if (!option || option.disabled) return;

    const requestId = makeActionRequestId();
    const pending = { requestId, requested: nextValue };
    permissionPendingRef.current = {
      ...permissionPendingRef.current,
      [threadId]: pending,
    };
    permissionRequestsRef.current.set(requestId, { threadId, requested: nextValue });
    setPermissionPending(permissionPendingRef.current);
    setPermissionErrors((prev) => ({ ...prev, [threadId]: null }));
    bridge.current.sendAction(`permissions:${nextValue}`, threadId, {
      requestId,
      silent: true,
    }, projectForThreadId(threadId));
  }, [permissionCapability]);

  const setThinking = useCallback((nextValue: string) => {
    if (!thinkingCapability) return;
    if (!thinkingCapability.options.some((o) => o.value === nextValue)) return;
    setThinkingValue(nextValue);   // 乐观显示；R 侧改状态并重连（下条消息 resume 生效）
    const threadId = currentThreadIdRef.current;
    bridge.current.sendAction(`thinking:${nextValue}`, threadId, {
      requestId: makeActionRequestId(),
      silent: true,
    }, projectForThreadId(threadId));
  }, [thinkingCapability]);
  const thinking = thinkingCapability
    ? {
        value: thinkingValue ?? thinkingCapability.value,
        options: thinkingCapability.options,
        setValue: setThinking,
      }
    : undefined;

  const setModel = useCallback((nextValue: string) => {
    if (!modelCapability) return;
    if (!modelCapability.options.some((o) => o.value === nextValue)) return;
    const threadId = currentThreadIdRef.current;
    if (modelPendingRef.current[threadId]) return;
    const requestId = makeActionRequestId();
    const pending = { requestId, requested: nextValue };
    const nextPending = { ...modelPendingRef.current, [threadId]: pending };
    modelPendingRef.current = nextPending;
    setModelPending(nextPending);
    setModelErrors((previous) => ({ ...previous, [threadId]: null }));
    modelRequestsRef.current.set(requestId, { threadId, requested: nextValue });
    bridge.current.sendAction(`model:${nextValue}`, threadId, {
      requestId,
      silent: true,
    }, projectForThreadId(threadId));
  }, [modelCapability]);
  const currentModelPending = modelPending[currentThreadId];
  const model = modelCapability
    ? {
        value: modelValues[currentThreadId] ?? modelCapability.value,
        options: modelCapability.options,
        pending: Boolean(currentModelPending),
        requested: currentModelPending?.requested ?? null,
        error: modelErrors[currentThreadId] ?? null,
        setValue: setModel,
        pickerOpen: modelPickerOpen,
        setPickerOpen: setModelPickerOpen,
      }
    : undefined;

  const currentPermissionPending = permissionPending[currentThreadId];
  const permissionMode: PermissionModeState | undefined = permissionCapability
    ? {
        value: currentPermissionPending?.requested
          ?? permissionValues[currentThreadId]
          ?? defaultPermissionMode
          ?? permissionCapability.value,
        options: permissionCapability.options,
        pending: Boolean(currentPermissionPending),
        error: permissionErrors[currentThreadId] ?? null,
        setValue: setPermissionMode,
      }
    : undefined;

  const checklistSnapshot = useMemo(
    () => buildChecklistSnapshot(messages),
    [messages],
  );
  const checklist = useMemo(() => {
    if (!checklistSnapshot.revision || checklistSnapshot.visibleItems.length === 0) return undefined;
    if (checklistSnapshot.staleAfterUserTurn) return undefined;
    if (dismissedChecklistRevisions[currentThreadId] === checklistSnapshot.revision) return undefined;
    return { ...checklistSnapshot, threadId: currentThreadId };
  }, [checklistSnapshot, currentThreadId, dismissedChecklistRevisions]);
  const dismissChecklist = useCallback((threadId: string, revision: string) => {
    if (!threadId || !revision) return;
    setDismissedChecklistRevisions((previous) => {
      if (previous[threadId] === revision) return previous;
      return { ...previous, [threadId]: revision };
    });
  }, []);
  const currentTaskMonitor = selectThreadTaskMonitor(taskMonitorState, currentThreadId);
  const latestTaskActivityId = latestTaskActivityIds[currentThreadId];
  const latestTaskActivity = latestTaskActivityId
    ? currentTaskMonitor.recentTerminal.find((task) => task.taskId === latestTaskActivityId)
    : undefined;
  const stopTask = useCallback((taskId: string) => {
    const threadId = currentThreadIdRef.current;
    const requested = requestTaskStop(taskMonitorStateRef.current, threadId, taskId);
    if (!requested.shouldDispatch) return;
    taskMonitorStateRef.current = requested.state;
    setTaskMonitorState(requested.state);
    invokeAction({ id: `stoptask:${taskId}`, label: "Stop task" });
  }, [invokeAction]);

  const runtime = useExternalStoreRuntime({
    messages,
    isRunning,
    isSendDisabled: isRunWaiting,
    suggestions,
    onNew,
    onEdit,
    onReload,
    onCancel,
    convertMessage: (m) => m,
    adapters: {
      threadList: threadListAdapter,
      attachments: attachmentAdapter.current,
      dictation: WebSpeechDictationAdapter.isSupported() ? new WebSpeechDictationAdapter() : undefined,
      speech: (typeof window !== "undefined" && "speechSynthesis" in window) ? new WebSpeechSynthesisAdapter() : undefined,
      feedback: feedbackAdapter.current,
    },
  });
  runtimeRef.current = runtime;

  useEffect(() => {
    const composer = runtimeRef.current?.thread.composer;
    if (!composer) return;
    const draft = composerDraftsRef.current.get(currentThreadId) ?? "";
    if (composer.getState().text !== draft) composer.setText(draft);
  }, [currentThreadId]);

  return {
    runtime, lazyToolResults: lazyToolResults.current,
    submissionRevision, sendToolApproval, switchToNewThread, newThreadInProject,
    renameThread, openFile, enqueueMessage,
    runInConsole, consoleRunEnabled,
    invokeAction, permissionMode, thinking, model,
    blockingAction: blockingActions[currentThreadId],
    ideContext: capabilityContract.ide ? ideContext : undefined,
    selectionVisible,
    setSelectionVisible,
    refreshIdeContext,
    workspaceMentions,
    searchWorkspace,
    // 工作目录选择器（addin）
    workingDir,
    gitBranch,
    recentDirs,
    nativePicker,
    pickWorkingDir: () => bridge.current.sendPickWorkingDir(),
    setWorkingDir: (path: string) => {
      if (workspaceMode) {
        workingDirRef.current = path;
        setWorkingDirState(path);
        setGitBranch(undefined);
        setWorkspaceProjectOrder((previous) =>
          previous.includes(path) ? previous : [path, ...previous]
        );
      }
      bridge.current.sendSetWorkingDir(path);
    },
    projects,
    workspaceProjectOrder,
    saveProject: () => bridge.current.sendSaveProject(),
    removeProject: (path: string) => bridge.current.sendRemoveProject(path),
    filesPaneFollow,
    setFilesPaneFollow: (value: boolean) => {
      setFilesPaneFollowState(value);
      bridge.current.sendFilesPaneFollow(value);
    },
    autoRunEnabled,
    setAutoRunEnabled: (value: boolean) => {
      setAutoRunEnabledState(value);
      bridge.current.sendAutoRunEnabled(value);
    },
    defaultPermissionMode,
    setDefaultPermissionMode: (value: string) => {
      setDefaultPermissionModeState(value);
      bridge.current.sendDefaultPermissionMode(value);
    },
    modeVisibility,
    setModeVisibility: (value: { showBypass: boolean; showYolo: boolean }) => {
      setModeVisibilityState(value);
      bridge.current.sendModeVisibility(value);
    },
    composerDensity,
    setComposerDensity: (value: "comfortable" | "compact") => {
      setComposerDensityState(value);
      bridge.current.sendComposerDensity(value);
    },
    assistantTextSize,
    setAssistantTextSize: (value: AssistantTextSize) => {
      setAssistantTextSizeState(value);
      bridge.current.sendAssistantTextSize(value);
    },
    runREnabled,
    setRunREnabled: (value: boolean) => {
      setRunREnabledState(value);
      bridge.current.sendRunREnabled(value);
    },
    autoStartCopilotApi,
    setAutoStartCopilotApi: (value: boolean) => {
      setAutoStartCopilotApiState(value);
      if (!value) {
        const disabled: CopilotServiceState = { status: "disabled", autoStart: false };
        serviceStateRef.current = disabled;
        setServiceState(disabled);
        cancelPendingSubmissions();
      } else {
        const checking: CopilotServiceState = {
          status: "checking", autoStart: true, message: "Checking copilot-api",
        };
        serviceStateRef.current = checking;
        setServiceState(checking);
      }
      copilotBridge.current?.setAutoStart(value);
    },
    serviceState,
    pendingServiceSubmissions,
    retryService: copilotBridge.current ? () => copilotBridge.current?.retry() : undefined,
    cancelPendingSubmissions,
    threadMaxWidth:
      typeof config?.thread_max_width === "string" ? config.thread_max_width : undefined,
    readingHistory: historyPageStates[currentThreadId]?.reading ?? false,
    historyHasMore: historyPageStates[currentThreadId]?.hasMore ?? false,
    historyCursor: historyPageStates[currentThreadId]?.cursor ?? null,
    loadingOlder: historyPageStates[currentThreadId]?.loadingOlder ?? false,
    loadOlderHistory,
    artifacts, activeArtifactId,
    openArtifact: (id: string) => setActiveArtifactIds((previous) => ({
      ...previous, [currentThreadId]: id,
    })),
    closeArtifact: () => setActiveArtifactIds((previous) => ({
      ...previous, [currentThreadId]: null,
    })),
    // ── ClaudeAgentSDK 能力对齐(当前线程视图)────────────────────────────────
    usage: usageMap[currentThreadId],                                    // #1
    agentState: agentStateMap[currentThreadId],                          // Plan 36
    tasks: currentTaskMonitor.active,                                    // #2
    recentTasks: isRunning && latestTaskActivity ? [latestTaskActivity] : [],
    checklist,
    dismissChecklist,
    rateLimit,                                                           // #3
    statusText,                                                          // #4
    serverCommands: serverCommandsByThread[currentThreadId] ?? [],       // #5
    commands,                                                            // 本地 skills(可 :commands 热更新)
    runPhase,
    runPhases: runPhaseMap,
    runStage,
    runStages: runStageMap,
    runQueuePosition,
    runQueuePositions: runQueuePositionMap,
    cancelRun: onCancel,
    workspaceMode,
    warming: warmingThreads.has(currentThreadId),                        // 每线程冷启动
    warmingResuming: warmingResumingThreads.has(currentThreadId),        // 该冷启动是否为"恢复历史"
    stopTask,
    forkThread: () => invokeAction({ id: "fork", label: "Fork conversation" }),                    // #6
  };
}
