"use client";

import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";
import { useShinyConfig } from "@/shiny-config-context";
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
  TrashIcon,
} from "lucide-react";
import {
  forwardRef,
  Fragment,
  useMemo,
  useState,
  type ComponentPropsWithoutRef,
  type FC,
} from "react";

export const ThreadList: FC = () => {
  const { workspaceMode } = useShinyConfig();

  return (
    <div
      data-slot="aui_thread-list-outer-scroll"
      className={cn(
        "h-full min-h-0",
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
          <ThreadListNew />
          <ThreadListItems />
          <ArchivedThreadListItems />
        </ThreadListRoot>
      </div>
    </div>
  );
};

// 方案B：归档区（可恢复）。仅在存在归档线程时显示；每项提供"取消归档"。
const ArchivedThreadListItems: FC = () => {
  const archivedIds = useAuiState((s) => s.threads.archivedThreadIds);
  const { workspaceMode } = useShinyConfig();
  if (!archivedIds || archivedIds.length === 0) return null;
  return (
    <div data-slot="aui_thread-list-archived" className="mt-2 min-w-0 border-t pt-2">
      <div className="text-muted-foreground px-2.5 pb-1 text-xs font-medium">Archived</div>
      {workspaceMode ? (
        <WorkspaceThreadGroups archived />
      ) : (
        <ThreadListPrimitive.Items archived components={{ ThreadListItem: ArchivedThreadListItem }} />
      )}
    </div>
  );
};

const ArchivedThreadListItem: FC = () => {
  return (
    <ThreadListItemPrimitive.Root
      data-slot="aui_thread-list-archived-item"
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

export const ThreadListItems: FC<ComponentPropsWithoutRef<"div">> = ({
  className,
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
        <ThreadListItemGroups />
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
  Item: FC;
}> = ({ group, threadIds, archived, initiallyExpanded, Item }) => {
  // The current project only supplies the mount-time default. After that, each
  // folder belongs entirely to the user: no current-thread effect and no accordion.
  const [expanded, setExpanded] = useState(initiallyExpanded);
  const count = group.indices.length;

  return (
    <div
      data-slot="aui_workspace-project-group"
      data-project={group.project}
      data-archived={archived ? "true" : "false"}
      data-expanded={expanded ? "true" : "false"}
      className="min-w-0"
    >
      <button
        type="button"
        data-slot="aui_workspace-project-header"
        data-project={group.project}
        title={group.project || group.label}
        aria-expanded={expanded}
        aria-label={`${expanded ? "Collapse" : "Expand"} ${group.label}`}
        onClick={() => setExpanded((current) => !current)}
        className="text-muted-foreground hover:bg-muted flex w-full min-w-0 items-center gap-1 rounded-md px-2 pt-3 pb-1 text-start text-xs font-medium transition-colors"
      >
        <ChevronRightIcon
          data-slot="aui_workspace-project-chevron"
          aria-hidden="true"
          className={cn(
            "size-3.5 shrink-0 transition-transform",
            expanded && "rotate-90",
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
      {expanded && (
        <div
          data-slot="aui_workspace-project-threads"
          className="ms-2 max-h-64 min-w-0 overflow-y-auto overscroll-contain border-s ps-1 pe-0.5"
        >
          {group.indices.map((index) => (
            <ThreadListPrimitive.ItemByIndex
              key={threadIds[index]}
              index={index}
              archived={archived}
              components={{ ThreadListItem: Item }}
            />
          ))}
        </div>
      )}
    </div>
  );
};

const WorkspaceThreadGroups: FC<{ archived?: boolean }> = ({ archived = false }) => {
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
    ? projectForThread(currentThread, "")
    : undefined;
  const groups = useMemo(() => {
    const itemsById = new Map(threadItems.map((item) => [item.id, item]));
    return groupWorkspaceThreads(threadIds, itemsById);
  }, [threadIds, threadItems]);
  const Item = archived ? ArchivedThreadListItem : ThreadListItem;

  return groups.map((group) => (
    <WorkspaceProjectGroup
      key={group.project || group.label}
      group={group}
      threadIds={threadIds}
      archived={archived}
      initiallyExpanded={
        !archived && currentProject !== undefined && group.project === currentProject
      }
      Item={Item}
    />
  ));
};

const ThreadListItemGroups: FC = () => {
  const { workspaceMode } = useShinyConfig();
  return workspaceMode ? <WorkspaceThreadGroups /> : <DateThreadListItemGroups />;
};

const DateThreadListItemGroups: FC = () => {
  const threadIds = useAuiState((s) => s.threads.threadIds);
  const threadItems = useAuiState((s) => s.threads.threadItems);

  const groups = useMemo<ThreadListGroup[] | null>(() => {
    const itemsById = new Map(threadItems.map((item) => [item.id, item]));
    const dates = threadIds.map((id) => itemsById.get(id)?.lastMessageAt);
    if (!dates.some(Boolean)) return null;

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
  }, [threadIds, threadItems]);

  if (!groups) {
    return (
      <ThreadListPrimitive.Items>
        {() => <ThreadListItem />}
      </ThreadListPrimitive.Items>
    );
  }

  return groups.map((group) => (
    <Fragment key={group.label}>
      <div
        data-slot="aui_thread-list-group-label"
        className="text-muted-foreground px-2.5 pt-3 pb-1 text-xs font-medium"
      >
        {group.label}
      </div>
      {group.indices.map((index) => (
        <ThreadListPrimitive.ItemByIndex
          key={threadIds[index]}
          index={index}
          components={{ ThreadListItem }}
        />
      ))}
    </Fragment>
  ));
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
