"use client";

import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";
import { useShinyConfig } from "@/shiny-config-context";
import { createThreadSearchIndex, matchThreadSearch, normalizeThreadSearch } from "@/thread-search";
import {
  groupWorkspaceThreads,
  projectForThread,
  type WorkspaceThreadGroup,
} from "@/workspace-threads";
import { Dialog, DialogContent, DialogTitle, DialogDescription, DialogClose } from "@/components/ui/dialog";
import {
  AuiIf,
  ThreadListItemMorePrimitive,
  ThreadListItemPrimitive,
  ThreadListPrimitive,
  useAuiState,
} from "@assistant-ui/react";
import {
  ArchiveIcon,
  ArchiveRestoreIcon,
  ChevronRightIcon,
  FolderIcon,
  GitBranchIcon,
  MoreHorizontalIcon,
  PencilIcon,
  PlusIcon,
  SearchIcon,
  TrashIcon,
  XIcon,
} from "lucide-react";
import {
  forwardRef,
  Fragment,
  useCallback,
  useDeferredValue,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type ComponentPropsWithoutRef,
  type FC,
} from "react";

export const ThreadList: FC = () => {
  const { workspaceMode } = useShinyConfig();
  const [collapseRevision, setCollapseRevision] = useState(0);
  const [query, setQuery] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  const scopeId = useId();
  const normalizedQuery = normalizeThreadSearch(query);
  const deferredQuery = useDeferredValue(normalizedQuery);
  const threadItems = useAuiState((s) => s.threads.threadItems);
  const threadIds = useAuiState((s) => s.threads.threadIds);
  const archivedIds = useAuiState((s) => s.threads.archivedThreadIds);
  const isLoading = useAuiState((s) => s.threads.isLoading);
  const index = useMemo(() => createThreadSearchIndex(threadItems), [threadItems]);
  const matchingIds = useMemo(
    () => matchThreadSearch(index, deferredQuery),
    [index, deferredQuery],
  );
  const resetSearch = useCallback(() => setQuery(""), []);
  const search = useMemo(
    () => ({ query: deferredQuery, matchingIds, reset: resetSearch }),
    [deferredQuery, matchingIds, resetSearch],
  );
  const count = [...threadIds, ...archivedIds].filter(
    (id) => !matchingIds || matchingIds.has(id),
  ).length;
  const isPending = normalizedQuery !== deferredQuery;
  const clearSearch = () => {
    resetSearch();
    inputRef.current?.focus();
  };

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div data-slot="aui_thread-list-search" className="shrink-0 pb-2">
        <div className="focus-within:ring-ring/50 relative flex items-center rounded-md border focus-within:ring-2">
          <SearchIcon aria-hidden="true" className="text-muted-foreground pointer-events-none absolute start-2 size-3.5" />
          <input
            ref={inputRef}
            type="search"
            aria-label="Search history"
            aria-describedby={scopeId}
            placeholder="Search history..."
            autoComplete="off"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={(event) => {
              event.stopPropagation();
              if (event.key === "Enter") event.preventDefault();
              if (event.key === "Escape" && !event.nativeEvent.isComposing) {
                event.preventDefault();
                clearSearch();
              }
            }}
            className="bg-background text-foreground h-8 w-full min-w-0 rounded-md ps-7 pe-8 text-sm outline-none [&::-webkit-search-cancel-button]:appearance-none"
          />
          {query && (
            <button
              type="button"
              aria-label="Clear search"
              title="Clear search"
              onClick={clearSearch}
              className="text-muted-foreground hover:text-foreground absolute end-1 flex size-6 items-center justify-center rounded"
            >
              <XIcon aria-hidden="true" className="size-3.5" />
            </button>
          )}
        </div>
        <p id={scopeId} className="text-muted-foreground mt-1 px-1 text-[10px] leading-tight">
          Titles and previews, including archived
        </p>
        {normalizedQuery && (
          <div role="status" aria-live="polite" className="text-muted-foreground mt-1 px-1 text-xs">
            {isPending ? "Searching..." : `${count} conversation${count === 1 ? "" : "s"}`}
          </div>
        )}
      </div>
      <div
        data-slot="aui_thread-list-outer-scroll"
        data-search-query={deferredQuery}
        aria-busy={isPending}
        className={cn(
          "min-h-0 flex-1",
          workspaceMode
            ? "overflow-y-scroll [scrollbar-color:var(--color-muted-foreground)_var(--color-muted)] [scrollbar-gutter:stable] [&::-webkit-scrollbar]:w-3 [&::-webkit-scrollbar-thumb:hover]:bg-muted-foreground/70 [&::-webkit-scrollbar-thumb]:rounded-full [&::-webkit-scrollbar-thumb]:bg-muted-foreground/50 [&::-webkit-scrollbar-track]:bg-muted/50"
            : "overflow-y-auto",
        )}
      >
      <div
        data-slot="aui_thread-list-outer-scroll-content"
        className={cn("min-w-0", workspaceMode && "pe-3")}
      >
        <ThreadListRoot>
          {workspaceMode ? (
            <button
              type="button"
              data-slot="aui_workspace-collapse-all"
              aria-label="Collapse all folders"
              title="Collapse all folders"
              onClick={() => {
                resetSearch();
                setCollapseRevision((revision) => revision + 1);
              }}
              className="text-muted-foreground hover:bg-muted h-8 min-w-0 truncate rounded-md px-2.5 text-start text-sm transition-colors"
            >
              Collapse all folders
            </button>
          ) : (
            <ThreadListNew onClick={resetSearch} />
          )}
          <ThreadListItems collapseRevision={collapseRevision} search={search} />
          <ArchivedThreadListItems collapseRevision={collapseRevision} search={search} />
          {!isLoading && !isPending && count === 0 && (
            <p data-slot="aui_thread-list-empty" className="text-muted-foreground px-2.5 py-3 text-sm">
              {deferredQuery ? "No matching conversations." : "No conversations yet."}
            </p>
          )}
        </ThreadListRoot>
      </div>
      </div>
    </div>
  );
};

type ThreadSearch = {
  query: string;
  matchingIds?: ReadonlySet<string>;
  reset?: () => void;
};
const EMPTY_SEARCH: ThreadSearch = { query: "" };
const THREAD_PAGE_SIZE = 100;

function useThreadListPage(query: string) {
  const [page, setPage] = useState({ query, limit: THREAD_PAGE_SIZE });
  const limit = page.query === query ? page.limit : THREAD_PAGE_SIZE;
  useEffect(() => {
    setPage((current) => current.query === query ? current : { query, limit: THREAD_PAGE_SIZE });
  }, [query]);
  return { limit, showMore: () => setPage({ query, limit: limit + THREAD_PAGE_SIZE }) };
}

const ThreadListShowMore: FC<{
  remaining: number;
  onClick: () => void;
  archived?: boolean;
}> = ({ remaining, onClick, archived }) => remaining > 0 ? (
  <button
    type="button"
    data-slot="aui_thread-list-load-more"
    aria-label={archived ? "Show more archived conversations" : "Show more conversations"}
    onClick={onClick}
    className="text-muted-foreground hover:bg-muted w-full rounded-md px-2.5 py-2 text-start text-xs"
  >
    Show more ({remaining} remaining)
  </button>
) : null;

// 方案B：归档区（可恢复）。仅在存在归档线程时显示；每项提供"取消归档"。
const ArchivedThreadListItems: FC<{ collapseRevision: number; search: ThreadSearch }> = ({
  collapseRevision, search,
}) => {
  const archivedIds = useAuiState((s) => s.threads.archivedThreadIds);
  const { workspaceMode } = useShinyConfig();
  if (!archivedIds || archivedIds.length === 0) return null;
  return (
    <div
      data-slot="aui_thread-list-archived"
      hidden={!!search.matchingIds && !archivedIds.some((id) => search.matchingIds?.has(id))}
      className="mt-2 min-w-0 border-t pt-2"
    >
      <div className="text-muted-foreground px-2.5 pb-1 text-xs font-medium">Archived</div>
      {workspaceMode ? (
        <WorkspaceThreadGroups archived collapseRevision={collapseRevision} search={search} />
      ) : (
        <DateThreadListItemGroups archived search={search} />
      )}
    </div>
  );
};

const ArchivedThreadListItem: FC = () => {
  const id = useAuiState((s) => s.threadListItem.id);
  return (
    <ThreadListItemPrimitive.Root
      data-slot="aui_thread-list-archived-item"
      data-thread-id={id}
      className="group hover:bg-accent focus-visible:bg-accent flex items-center gap-2 rounded-lg px-2.5 py-2 text-sm outline-none"
    >
      <ThreadListItemPrimitive.Trigger className="aui-thread-list-item-trigger min-w-0 flex-1 truncate text-start">
        <ThreadListItemPrimitive.Title />
      </ThreadListItemPrimitive.Trigger>
      <ThreadListItemPrimitive.Unarchive asChild>
        <Button
          variant="ghost"
          size="icon"
          data-slot="aui_thread-list-unarchive"
          className="size-6 shrink-0 p-0 opacity-0 group-hover:opacity-100"
          aria-label="Unarchive"
          title="Unarchive"
        >
          <ArchiveRestoreIcon className="size-3.5" />
        </Button>
      </ThreadListItemPrimitive.Unarchive>
    </ThreadListItemPrimitive.Root>
  );
};

export const ThreadListRoot: FC<
  ComponentPropsWithoutRef<typeof ThreadListPrimitive.Root>
> = ({ className, ...props }) => {
  return (
    <ThreadListPrimitive.Root
      data-slot="aui_thread-list-root"
      className={cn("flex min-w-0 flex-col gap-0.5 overflow-hidden", className)}
      {...props}
    />
  );
};

export const ThreadListItems: FC<
  ComponentPropsWithoutRef<"div"> & { collapseRevision?: number; search?: ThreadSearch }
> = ({
  className,
  collapseRevision = 0,
  search = EMPTY_SEARCH,
  ...props
}) => {
  return (
    <div
      data-slot="aui_thread-list-items"
      className={cn("flex flex-col gap-0.5", className)}
      {...props}
    >
      <AuiIf condition={(s) => s.threads.isLoading}>
        <ThreadListSkeleton />
      </AuiIf>
      <AuiIf condition={(s) => !s.threads.isLoading}>
        <ThreadListItemGroups collapseRevision={collapseRevision} search={search} />
      </AuiIf>
    </div>
  );
};

const DAY_IN_MS = 86_400_000;

const dateGroupLabel = (
  date: Date | undefined,
  startOfToday: number,
): string => {
  if (!date || date.getTime() >= startOfToday) return "Today";
  if (date.getTime() >= startOfToday - DAY_IN_MS) return "Yesterday";
  return "Earlier";
};

type ThreadListGroup = { label: string; indices: number[] };

const WorkspaceProjectGroup: FC<{
  group: WorkspaceThreadGroup;
  threadIds: readonly string[];
  archived: boolean;
  initiallyExpanded: boolean;
  collapseRevision: number;
  Item: FC;
  search: ThreadSearch;
  searchIndices: number[];
  searchCount: number;
}> = ({
  group,
  threadIds,
  archived,
  initiallyExpanded,
  collapseRevision,
  Item,
  search,
  searchIndices,
  searchCount,
}) => {
  const { newThreadInProject } = useShinyConfig();
  // The current project only supplies the mount-time default. After that, each
  // folder belongs entirely to the user: no current-thread effect and no accordion.
  const [expanded, setExpanded] = useState(initiallyExpanded);
  const { limit, showMore } = useThreadListPage("");
  const previousCollapseRevision = useRef(collapseRevision);
  useEffect(() => {
    if (previousCollapseRevision.current === collapseRevision) return;
    previousCollapseRevision.current = collapseRevision;
    setExpanded(false);
  }, [collapseRevision]);
  const searching = !!search.query;
  // Filtering reveals results without overwriting the user's folder choices.
  const isExpanded = searching || expanded;
  const count = searching ? searchCount : group.indices.length;
  const visibleIndices = searching ? searchIndices : group.indices.slice(0, limit);

  return (
    <div
      data-slot="aui_workspace-project-group"
      data-project={group.project}
      data-archived={archived ? "true" : "false"}
      data-expanded={isExpanded ? "true" : "false"}
      hidden={searching && searchIndices.length === 0}
      className="min-w-0"
    >
      <div className="flex min-w-0 items-end gap-0.5">
        <button
          type="button"
          data-slot="aui_workspace-project-header"
          data-project={group.project}
          title={group.project || group.label}
          aria-expanded={isExpanded}
          aria-label={searching ? `Search results in ${group.label}` : `${expanded ? "Collapse" : "Expand"} ${group.label}`}
          disabled={searching}
          onClick={() => setExpanded((current) => !current)}
          className="text-muted-foreground hover:bg-muted flex min-w-0 flex-1 items-center gap-1 rounded-md px-2 pt-3 pb-1 text-start text-xs font-medium transition-colors"
        >
          <ChevronRightIcon
            data-slot="aui_workspace-project-chevron"
            aria-hidden="true"
            className={cn(
              "size-3.5 shrink-0 transition-transform",
              isExpanded && "rotate-90",
            )}
          />
          <FolderIcon
            data-slot="aui_workspace-project-folder"
            aria-hidden="true"
            className="size-3.5 shrink-0"
          />
          <span data-slot="aui_workspace-project-label" className="min-w-0 flex-1 truncate">
            {group.label}
          </span>
          <span
            data-slot="aui_workspace-thread-count"
            aria-label={`${count} conversation${count === 1 ? "" : "s"}`}
            title={`${count} conversation${count === 1 ? "" : "s"}`}
            className="shrink-0 text-[10px] leading-none tabular-nums opacity-70"
          >
            {count}
          </span>
          {group.activeRuns > 0 && (
            <span
              data-slot="aui_workspace-run-count"
              className="bg-muted shrink-0 rounded px-1 py-0.5 text-[10px] leading-none tabular-nums"
            >
              {group.activeRuns} run{group.activeRuns === 1 ? "" : "s"}
            </span>
          )}
          {group.activeTasks > 0 && (
            <span
              data-slot="aui_workspace-task-count"
              className="bg-muted shrink-0 rounded px-1 py-0.5 text-[10px] leading-none tabular-nums"
            >
              {group.activeTasks} task{group.activeTasks === 1 ? "" : "s"}
            </span>
          )}
        </button>
        {!archived && group.project && newThreadInProject && (
          <button
            type="button"
            data-slot="aui_workspace-project-new"
            data-project={group.project}
            aria-label={`New chat in ${group.label}`}
            title={`New chat in ${group.label}`}
            onClick={() => {
              setExpanded(true);
              search.reset?.();
              newThreadInProject(group.project);
            }}
            className="text-muted-foreground hover:bg-muted hover:text-foreground mb-0.5 flex size-7 shrink-0 items-center justify-center rounded-md transition-colors"
          >
            <PlusIcon className="size-3.5" />
          </button>
        )}
      </div>
      {isExpanded && (!searching || searchIndices.length > 0) && (
        <div
          data-slot="aui_workspace-project-threads"
          className="ms-2 max-h-64 min-w-0 overflow-y-auto overscroll-contain border-s ps-1 pe-0.5"
        >
          {visibleIndices.map((index) => (
            <ThreadListPrimitive.ItemByIndex
              key={threadIds[index]}
              index={index}
              archived={archived}
              components={{ ThreadListItem: Item }}
            />
          ))}
          {!searching && (
            <ThreadListShowMore remaining={count - limit} onClick={showMore} archived={archived} />
          )}
        </div>
      )}
    </div>
  );
};

const WorkspaceThreadGroups: FC<{
  archived?: boolean;
  collapseRevision?: number;
  search: ThreadSearch;
}> = ({ archived = false, collapseRevision = 0, search }) => {
  const { workspaceProjectOrder, workingDir } = useShinyConfig();
  const threadIds = useAuiState((s) =>
    archived ? s.threads.archivedThreadIds : s.threads.threadIds,
  );
  const mainThreadId = useAuiState((s) => s.threads.mainThreadId);
  const threadItems = useAuiState((s) => s.threads.threadItems);
  const currentThread = useMemo(
    () => threadItems.find((item) => item.id === mainThreadId),
    [mainThreadId, threadItems],
  );
  const currentProject = currentThread
    ? projectForThread(currentThread, workingDir || "")
    : workingDir || undefined;
  const groups = useMemo(() => {
    const itemsById = new Map(threadItems.map((item) => [item.id, item]));
    return groupWorkspaceThreads(
      threadIds,
      itemsById,
      workspaceProjectOrder,
      !archived,
    );
  }, [archived, threadIds, threadItems, workspaceProjectOrder]);
  const Item = archived ? ArchivedThreadListItem : ThreadListItem;
  const { limit, showMore } = useThreadListPage(search.query);
  const filteredGroups = useMemo(() => groups.map((group) => ({
    ...group,
    indices: search.matchingIds
      ? group.indices.filter((index) => search.matchingIds?.has(threadIds[index]))
      : group.indices,
  })), [groups, search.matchingIds, threadIds]);
  const total = filteredGroups.reduce((sum, group) => sum + group.indices.length, 0);
  let remaining = limit;

  return <>{groups.map((group, groupIndex) => {
    const matchingIndices = filteredGroups[groupIndex].indices;
    const searchIndices = matchingIndices.slice(0, Math.max(0, remaining));
    remaining -= searchIndices.length;
    return (
    <WorkspaceProjectGroup
      key={group.project || group.label}
      group={group}
      threadIds={threadIds}
      archived={archived}
      collapseRevision={collapseRevision}
      initiallyExpanded={
        !archived && currentProject !== undefined && group.project === currentProject
      }
      Item={Item}
      search={search}
      searchIndices={searchIndices}
      searchCount={matchingIndices.length}
    />
    );
  })}
    {search.query && (
      <ThreadListShowMore remaining={total - limit} onClick={showMore} archived={archived} />
    )}
  </>;
};

const ThreadListItemGroups: FC<{ collapseRevision: number; search: ThreadSearch }> = ({
  collapseRevision, search,
}) => {
  const { workspaceMode } = useShinyConfig();
  return workspaceMode ? (
    <WorkspaceThreadGroups collapseRevision={collapseRevision} search={search} />
  ) : (
    <DateThreadListItemGroups search={search} />
  );
};

const DateThreadListItemGroups: FC<{ archived?: boolean; search: ThreadSearch }> = ({
  archived = false, search,
}) => {
  const threadIds = useAuiState((s) => archived ? s.threads.archivedThreadIds : s.threads.threadIds);
  const threadItems = useAuiState((s) => s.threads.threadItems);
  const { limit, showMore } = useThreadListPage(search.query);
  const Item = archived ? ArchivedThreadListItem : ThreadListItem;

  const groups = useMemo<ThreadListGroup[]>(() => {
    const itemsById = new Map(threadItems.map((item) => [item.id, item]));
    const dates = threadIds.map((id) => itemsById.get(id)?.lastMessageAt);
    if (archived || !dates.some(Boolean)) {
      return [{ label: "", indices: threadIds.map((_, index) => index) }];
    }

    const now = new Date();
    const startOfToday = new Date(
      now.getFullYear(),
      now.getMonth(),
      now.getDate(),
    ).getTime();
    const time = (index: number) =>
      dates[index]?.getTime() ?? Number.MAX_SAFE_INTEGER;
    const indices = threadIds
      .map((_, index) => index)
      .sort((a, b) => time(b) - time(a));

    const result: ThreadListGroup[] = [];
    for (const index of indices) {
      const label = dateGroupLabel(dates[index], startOfToday);
      const lastGroup = result[result.length - 1];
      if (lastGroup?.label === label) {
        lastGroup.indices.push(index);
      } else {
        result.push({ label, indices: [index] });
      }
    }
    return result;
  }, [archived, threadIds, threadItems]);
  const filteredGroups = useMemo(() => groups.map((group) => ({
    ...group,
    indices: search.matchingIds
      ? group.indices.filter((index) => search.matchingIds?.has(threadIds[index]))
      : group.indices,
  })), [groups, search.matchingIds, threadIds]);
  const total = filteredGroups.reduce((sum, group) => sum + group.indices.length, 0);
  let remaining = limit;

  return <>{filteredGroups.map((group) => {
    const visible = group.indices.slice(0, Math.max(0, remaining));
    remaining -= visible.length;
    if (visible.length === 0) return null;
    return (
    <Fragment key={group.label}>
      {group.label && <div
        data-slot="aui_thread-list-group-label"
        className="text-muted-foreground px-2.5 pt-3 pb-1 text-xs font-medium"
      >
        {group.label}
      </div>}
      {visible.map((index) => (
        <ThreadListPrimitive.ItemByIndex
          key={threadIds[index]}
          index={index}
          archived={archived}
          components={{ ThreadListItem: Item }}
        />
      ))}
    </Fragment>
    );
  })}
    <ThreadListShowMore remaining={total - limit} onClick={showMore} archived={archived} />
  </>;
};

export const ThreadListNew = forwardRef<
  HTMLButtonElement,
  ComponentPropsWithoutRef<typeof Button> & { labelClassName?: string }
>(({ className, labelClassName, children, ...props }, ref) => {
  return (
    <ThreadListPrimitive.New asChild>
      <Button
        ref={ref}
        variant="ghost"
        data-slot="aui_thread-list-new"
        className={cn(
          "hover:bg-muted data-active:bg-muted h-8 min-w-0 justify-start gap-2 rounded-md px-2.5 text-sm font-normal",
          className,
        )}
        {...props}
      >
        {children ?? (
          <>
            <PlusIcon
              data-slot="aui_thread-list-new-icon"
              className="size-4 shrink-0"
            />
            <span
              data-slot="aui_thread-list-new-label"
              className={cn("min-w-0 truncate whitespace-nowrap", labelClassName)}
            >
              New Thread
            </span>
          </>
        )}
      </Button>
    </ThreadListPrimitive.New>
  );
});

ThreadListNew.displayName = "ThreadListNew";

const ThreadListSkeleton: FC = () => {
  return (
    <div className="flex flex-col gap-0.5">
      {Array.from({ length: 5 }, (_, i) => (
        <div
          key={i}
          role="status"
          aria-label="Loading threads"
          data-slot="aui_thread-list-skeleton-wrapper"
          className="flex h-8 items-center px-2.5"
        >
          <Skeleton
            data-slot="aui_thread-list-skeleton"
            className="h-3.5 w-full"
          />
        </div>
      ))}
    </div>
  );
};

export const ThreadListItem: FC = () => {
  const id = useAuiState((s) => s.threadListItem.id);
  const title = useAuiState((s) => s.threadListItem.title as string | undefined);
  const runPhase = useAuiState((s) => s.threadListItem.custom?.runPhase as
    | "queued" | "connecting" | "running" | undefined);
  const { onRename } = useShinyConfig();
  const [renaming, setRenaming] = useState(false);
  const [draft, setDraft] = useState("");
  const startRename = () => { setDraft(title ?? ""); setRenaming(true); };
  const commitRename = () => { if (draft.trim()) onRename(id, draft); setRenaming(false); };

  return (
    <ThreadListItemPrimitive.Root
      data-slot="aui_thread-list-item"
      data-thread-id={id}
      className="group hover:bg-muted focus-visible:bg-muted data-active:bg-muted has-focus-visible:bg-muted has-data-[state=open]:bg-muted relative flex h-8 items-center rounded-md transition-colors focus-visible:outline-none"
    >
      {renaming ? (
        <input
          autoFocus
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onClick={(e) => e.stopPropagation()}
          onKeyDown={(e) => {
            e.stopPropagation();
            if (e.key === "Enter") commitRename();
            else if (e.key === "Escape") setRenaming(false);
          }}
          onBlur={commitRename}
          className="aui-thread-rename-input bg-background text-foreground focus:ring-ring/50 mx-1 h-6 min-w-0 flex-1 rounded border px-2 text-sm outline-none focus:ring-[3px]"
        />
      ) : (
        <ThreadListItemPrimitive.Trigger
          data-slot="aui_thread-list-item-trigger"
          className="focus-visible:ring-ring/50 flex h-full min-w-0 flex-1 items-center rounded-md px-2.5 text-start text-sm outline-none group-hover:pe-9 group-has-focus-visible:pe-9 group-has-data-[state=open]:pe-9 group-data-active:pe-9 focus-visible:ring-[3px]"
        >
          <span
            data-slot="aui_thread-list-item-title"
            className="min-w-0 flex-1 truncate"
          >
            <ThreadListItemPrimitive.Title fallback="New Chat" />
          </span>
          {runPhase && (
            <span
              data-slot="aui_thread-list-run-phase"
              data-run-phase={runPhase}
              role="status"
              title={runPhase === "queued" ? "Waiting" : runPhase === "connecting" ? "Connecting" : "Running"}
              className={cn(
                "ms-2 size-2 shrink-0 rounded-full",
                runPhase === "running" && "bg-primary animate-pulse",
                runPhase === "connecting" && "bg-amber-500",
                runPhase === "queued" && "bg-muted-foreground",
              )}
            >
              <span className="sr-only">{runPhase}</span>
            </span>
          )}
        </ThreadListItemPrimitive.Trigger>
      )}
      {!renaming && <ThreadListItemMore onRename={startRename} />}
    </ThreadListItemPrimitive.Root>
  );
};

const ThreadListItemMore: FC<{ onRename: () => void }> = ({ onRename }) => {
  const { forkThread } = useShinyConfig();
  const [confirmOpen, setConfirmOpen] = useState(false);
  return (
    <>
    <ThreadListItemMorePrimitive.Root sharedFocusGroup>
      <ThreadListItemMorePrimitive.Trigger asChild>
        <Button
          variant="ghost"
          size="icon"
          data-slot="aui_thread-list-item-more"
          className="data-[state=open]:bg-accent absolute end-1.5 top-1/2 size-6 -translate-y-1/2 p-0 opacity-0 group-hover:opacity-100 group-has-focus-visible:opacity-100 group-data-active:opacity-100 data-[state=open]:opacity-100"
        >
          <MoreHorizontalIcon className="size-3.5" />
          <span className="sr-only">More options</span>
        </Button>
      </ThreadListItemMorePrimitive.Trigger>
      <ThreadListItemMorePrimitive.Content
        side="right"
        align="start"
        sideOffset={6}
        data-slot="aui_thread-list-item-more-content"
        className="bg-popover/95 text-popover-foreground data-[state=open]:fade-in-0 data-[state=open]:zoom-in-95 data-[state=open]:animate-in data-[state=closed]:fade-out-0 data-[state=closed]:zoom-out-95 data-[state=closed]:animate-out data-[side=bottom]:slide-in-from-top-2 data-[side=left]:slide-in-from-right-2 data-[side=right]:slide-in-from-left-2 data-[side=top]:slide-in-from-bottom-2 z-50 min-w-32 overflow-hidden rounded-xl border p-1.5 shadow-lg backdrop-blur-sm"
      >
        <ThreadListItemMorePrimitive.Item
          data-slot="aui_thread-list-item-more-item"
          onClick={onRename}
          className="aui-thread-rename-btn hover:bg-accent hover:text-accent-foreground focus:bg-accent focus:text-accent-foreground flex cursor-pointer items-center gap-2 rounded-lg px-2.5 py-1.5 text-sm outline-none select-none"
        >
          <PencilIcon className="size-4" />
          Rename
        </ThreadListItemMorePrimitive.Item>
        {forkThread && (
          <ThreadListItemMorePrimitive.Item
            data-slot="aui_thread-list-item-more-item"
            data-fork-thread
            onClick={() => forkThread()}
            className="aui-thread-fork-btn hover:bg-accent hover:text-accent-foreground focus:bg-accent focus:text-accent-foreground flex cursor-pointer items-center gap-2 rounded-lg px-2.5 py-1.5 text-sm outline-none select-none"
          >
            <GitBranchIcon className="size-4" />
            Fork
          </ThreadListItemMorePrimitive.Item>
        )}
        <ThreadListItemPrimitive.Archive asChild>
          <ThreadListItemMorePrimitive.Item
            data-slot="aui_thread-list-item-more-item"
            className="hover:bg-accent hover:text-accent-foreground focus:bg-accent focus:text-accent-foreground flex cursor-pointer items-center gap-2 rounded-lg px-2.5 py-1.5 text-sm outline-none select-none"
          >
            <ArchiveIcon className="size-4" />
            Archive
          </ThreadListItemMorePrimitive.Item>
        </ThreadListItemPrimitive.Archive>
        {/* Delete 打开二次确认，不直接删除（不可逆）。 */}
        <ThreadListItemMorePrimitive.Item
          data-slot="aui_thread-list-item-more-item"
          data-delete-request
          onClick={(event) => {
            event.preventDefault();
            setConfirmOpen(true);
          }}
          className="text-destructive hover:bg-destructive/10 hover:text-destructive focus:bg-destructive/10 focus:text-destructive flex cursor-pointer items-center gap-2 rounded-lg px-2.5 py-1.5 text-sm outline-none select-none"
        >
          <TrashIcon className="size-4" />
          Delete
        </ThreadListItemMorePrimitive.Item>
      </ThreadListItemMorePrimitive.Content>
    </ThreadListItemMorePrimitive.Root>
    <Dialog open={confirmOpen} onOpenChange={setConfirmOpen}>
      <DialogContent
        data-slot="aui_delete_confirm"
        showCloseButton={false}
        className="w-[min(24rem,90vw)] gap-0"
      >
        <DialogTitle className="text-base font-semibold">Delete this conversation permanently?</DialogTitle>
        <DialogDescription className="text-muted-foreground mt-1.5 text-sm">
          This removes the session transcript from disk and cannot be undone. To just hide it, use Archive instead.
        </DialogDescription>
        <div className="mt-4 flex justify-end gap-2">
          <DialogClose render={<Button variant="outline" size="sm" data-cancel-delete>Cancel</Button>} />
          <ThreadListItemPrimitive.Delete asChild>
            <Button variant="destructive" size="sm" data-confirm-delete onClick={() => setConfirmOpen(false)}>Delete permanently</Button>
          </ThreadListItemPrimitive.Delete>
        </div>
      </DialogContent>
    </Dialog>
    </>
  );
};
