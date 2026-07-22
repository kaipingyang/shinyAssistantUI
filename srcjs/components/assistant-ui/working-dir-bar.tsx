"use client";

import { useState, type FC } from "react";
import { FolderIcon, ChevronDownIcon, StarIcon, XIcon } from "lucide-react";
import { useShinyConfig } from "@/shiny-config-context";

/**
 * 侧栏顶部工作目录选择器（addin）。先选目录 → 刷新该目录 sessions → 再决定新聊/续聊。
 * RStudio 有原生目录弹窗（nativePicker）→ 点击直接开；浏览器 → 展开手输框 + 最近目录。
 * 仅当 config 带 workingDir（addin 模式）时渲染。
 */
export const WorkingDirBar: FC = () => {
  const {
    workingDir, recentDirs, nativePicker, pickWorkingDir, setWorkingDir,
    projects, saveProject, removeProject,
    filesPaneFollow, setFilesPaneFollow,
  } = useShinyConfig();
  const [editing, setEditing] = useState(false);
  const [favOpen, setFavOpen] = useState(false);   // 收藏默认收起，展开滚动
  if (!workingDir) return null;

  const base = workingDir.replace(/\/+$/, "").split("/").pop() || workingDir;
  const dirBase = (d: string) => d.replace(/\/+$/, "").split("/").pop() || d;
  const change = () => {
    if (nativePicker && pickWorkingDir) {
      pickWorkingDir();
      return;
    }
    setEditing((v) => !v);
  };
  const submit = (path: string) => {
    const p = path.trim();
    if (p && setWorkingDir) setWorkingDir(p);
    setEditing(false);
  };
  const saved = projects ?? [];
  const isSaved = saved.includes(workingDir);

  return (
    <div
      data-slot="aui_working_dir"
      data-working-dir={workingDir}
      className="mb-1 flex flex-col gap-1 border-b pb-1.5"
    >
      <div className="flex items-center gap-0.5">
        <button
          type="button"
          data-slot="aui_working_dir_change"
          onClick={change}
          title={workingDir}
          className="hover:bg-accent text-muted-foreground flex min-w-0 flex-1 items-center gap-1.5 rounded-md px-2 py-1 text-xs transition-colors"
        >
          <FolderIcon className="size-3.5 shrink-0" />
          <span className="text-foreground min-w-0 flex-1 truncate text-start font-medium">{base}</span>
          <ChevronDownIcon className="size-3 shrink-0 opacity-60" />
        </button>
        {saveProject && (
          <button
            type="button"
            data-slot="aui_working_dir_save"
            onClick={() => saveProject()}
            aria-label="Save current folder to favorites"
            title={isSaved ? "Saved to favorites" : "Save current folder to favorites"}
            className="hover:bg-accent flex size-7 shrink-0 items-center justify-center rounded-md"
          >
            <StarIcon className={"size-3.5 " + (isSaved ? "fill-yellow-400 text-yellow-500" : "text-muted-foreground")} />
          </button>
        )}
      </div>
      {editing && !nativePicker && (
        <div className="flex flex-col gap-1 px-1">
          <input
            data-slot="aui_working_dir_input"
            defaultValue={workingDir}
            autoFocus
            placeholder="Working directory path…"
            onKeyDown={(e) => {
              if (e.key === "Enter") submit((e.target as HTMLInputElement).value);
              else if (e.key === "Escape") setEditing(false);
            }}
            className="border-input bg-background h-7 rounded-md border px-2 text-xs outline-none"
          />
          {(recentDirs ?? []).length > 0 && (
            <div className="flex flex-col">
              {(recentDirs ?? []).map((d) => (
                <button
                  key={d}
                  type="button"
                  data-slot="aui_working_dir_recent"
                  onClick={() => submit(d)}
                  title={d}
                  className="hover:bg-accent text-muted-foreground truncate rounded px-2 py-0.5 text-start text-[11px]"
                >
                  {d}
                </button>
              ))}
            </div>
          )}
        </div>
      )}
      {filesPaneFollow !== undefined && (
        <label
          data-slot="aui_files_pane_follow"
          className="text-muted-foreground hover:text-foreground flex cursor-pointer items-center gap-1.5 px-2 py-0.5 text-[11px]"
          title="Navigate the RStudio Files pane when you switch folders"
        >
          <input
            type="checkbox"
            checked={filesPaneFollow}
            onChange={(e) => setFilesPaneFollow?.(e.target.checked)}
            className="size-3 accent-current"
          />
          <span>Sync Files pane to folder</span>
        </label>
      )}
      {saved.length > 0 && (
        <div data-slot="aui_projects" className="flex flex-col">
          <button
            type="button"
            data-slot="aui_projects_toggle"
            aria-expanded={favOpen}
            onClick={() => setFavOpen((v) => !v)}
            className="text-muted-foreground hover:bg-accent flex items-center gap-1 rounded px-2 pt-0.5 pb-0.5 text-[10px] font-semibold tracking-wide uppercase"
          >
            <ChevronDownIcon className={"size-3 transition-transform " + (favOpen ? "" : "-rotate-90")} />
            <span>Favorites ({saved.length})</span>
          </button>
          {favOpen && (
            <div data-slot="aui_projects_list" className="flex max-h-40 flex-col overflow-y-auto">
              {saved.map((d) => (
                <div
                  key={d}
                  data-slot="aui_project_item"
                  data-project={d}
                  className="group hover:bg-accent flex items-center gap-1 rounded-md pe-1"
                >
                  <button
                    type="button"
                    data-slot="aui_project_jump"
                    onClick={() => setWorkingDir?.(d)}
                    title={d}
                    className="text-muted-foreground min-w-0 flex-1 truncate px-2 py-1 text-start text-xs"
                  >
                    {dirBase(d)}
                  </button>
                  {removeProject && (
                    <button
                      type="button"
                      data-slot="aui_project_remove"
                      onClick={() => removeProject(d)}
                      aria-label="Remove from favorites"
                      title="Remove from favorites"
                      className="hover:bg-destructive/10 hover:text-destructive text-muted-foreground flex size-5 shrink-0 items-center justify-center rounded opacity-0 group-hover:opacity-100"
                    >
                      <XIcon className="size-3" />
                    </button>
                  )}
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
};
