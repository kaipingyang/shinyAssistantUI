import type { ExternalStoreThreadData } from "@assistant-ui/core";
import type { SessionItem } from "./bridge";

export type WorkspaceThreadCustom = {
  project?: string;
  projectLabel?: string;
  runPhase?: string;
  activeTaskCount?: number;
};

type ThreadStatus = "regular" | "archived";
export type WorkspaceThreadLike = {
  id: string;
  custom?: unknown;
};

export type WorkspaceThreadGroup = {
  project: string;
  label: string;
  indices: number[];
  activeRuns: number;
  activeTasks: number;
};

const nonEmptyString = (value: unknown): value is string =>
  typeof value === "string" && value.trim().length > 0;

export const projectLabel = (project: string): string => {
  const normalized = project.replace(/[\\/]+$/, "");
  const parts = normalized.split(/[\\/]/).filter(Boolean);
  const leaf = parts[parts.length - 1];
  return leaf || project || "Other";
};

export function projectForThread(
  thread: { custom?: unknown } | undefined,
  fallback?: string,
): string | undefined {
  const custom = thread?.custom as Record<string, unknown> | undefined;
  return nonEmptyString(custom?.project) ? custom.project : fallback;
}

export function sessionsToWorkspaceThreads<T extends ThreadStatus>(
  sessions: SessionItem[],
  status: T,
): ExternalStoreThreadData<T>[] {
  return sessions.map((session) => {
    const custom = nonEmptyString(session.project)
      ? {
          project: session.project,
          projectLabel: nonEmptyString(session.projectLabel)
            ? session.projectLabel
            : projectLabel(session.project),
        }
      : undefined;
    return {
      id: session.id,
      status,
      title: session.title || session.id,
      ...(custom ? { custom } : {}),
    } as ExternalStoreThreadData<T>;
  });
}

export function groupWorkspaceThreads(
  threadIds: readonly string[],
  itemsById: ReadonlyMap<string, WorkspaceThreadLike | undefined>,
): WorkspaceThreadGroup[] {
  const groups: WorkspaceThreadGroup[] = [];
  const byProject = new Map<string, WorkspaceThreadGroup>();

  threadIds.forEach((id, index) => {
    const thread = itemsById.get(id);
    const custom = (thread?.custom ?? {}) as Record<string, unknown>;
    const project = nonEmptyString(custom.project) ? custom.project : "";
    let group = byProject.get(project);
    if (!group) {
      group = {
        project,
        label: nonEmptyString(custom.projectLabel)
          ? custom.projectLabel
          : projectLabel(project),
        indices: [],
        activeRuns: 0,
        activeTasks: 0,
      };
      byProject.set(project, group);
      groups.push(group);
    }
    group.indices.push(index);
    if (["queued", "connecting", "running"].includes(String(custom.runPhase ?? ""))) {
      group.activeRuns += 1;
    }
    if (typeof custom.activeTaskCount === "number" && Number.isFinite(custom.activeTaskCount)) {
      group.activeTasks += Math.max(0, Math.floor(custom.activeTaskCount));
    }
  });

  return groups;
}
