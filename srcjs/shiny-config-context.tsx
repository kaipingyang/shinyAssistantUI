import { createContext, useContext } from "react";
import type { IdeContextMeta, WorkspaceMentionItem } from "./bridge";

export interface ShinyCommand { name: string; description?: string; prompt: string; category?: string; source?: string; kind?: string; }
export interface ShinyToolItem { name: string; description?: string; }
export interface ShinyActionItem { section?: string; id: string; command?: string; label?: string; description?: string; }
export interface PermissionModeOption {
  value: string;
  label: string;
  description?: string;
  disabled?: boolean;
}
export interface PermissionModeState {
  value: string;
  options: PermissionModeOption[];
  pending: boolean;
  error: string | null;
  setValue: (value: string) => void;
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
  onEnqueue: (text: string) => void;
  onRename: (threadId: string, title: string) => void;
  onInvokeAction: (item: ShinyActionItem) => void;
  permissionMode?: PermissionModeState;
  ideContext?: IdeContextMeta;
  selectionVisible: boolean;
  setSelectionVisible: (visible: boolean) => void;
  refreshIdeContext: () => void;
  workspaceMentions: WorkspaceMentionState;
  searchWorkspace: (query: string) => void;
  // ── ClaudeAgentSDK 能力对齐 ──
  usage?: { costUsd?: number; tokens?: number; turns?: number; durationMs?: number; model?: string };
  tasks?: Array<{ taskId: string; kind: string; description?: string; status?: string; toolName?: string; summary?: string }>;
  rateLimit?: { status?: string; resetsAt?: string; utilization?: number; type?: string } | null;
  statusText?: string | null;
  warming?: boolean;
  stopTask?: (taskId: string) => void;
  forkThread?: () => void;
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
});

export const useShinyConfig = () => useContext(ShinyConfigContext);
