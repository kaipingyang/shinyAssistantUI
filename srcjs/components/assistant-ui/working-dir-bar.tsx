"use client";

import { useState, type FC } from "react";
import { FolderIcon, ChevronDownIcon } from "lucide-react";
import { useShinyConfig } from "@/shiny-config-context";

/**
 * 侧栏顶部工作目录选择器（addin）。先选目录 → 刷新该目录 sessions → 再决定新聊/续聊。
 * RStudio 有原生目录弹窗（nativePicker）→ 点击直接开；浏览器 → 展开手输框 + 最近目录。
 * 仅当 config 带 workingDir（addin 模式）时渲染。
 */
export const WorkingDirBar: FC = () => {
  const { workingDir, recentDirs, nativePicker, pickWorkingDir, setWorkingDir } =
    useShinyConfig();
  const [editing, setEditing] = useState(false);
  if (!workingDir) return null;

  const base = workingDir.replace(/\/+$/, "").split("/").pop() || workingDir;
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

  return (
    <div
      data-slot="aui_working_dir"
      data-working-dir={workingDir}
      className="mb-1 flex flex-col gap-1 border-b pb-1.5"
    >
      <button
        type="button"
        data-slot="aui_working_dir_change"
        onClick={change}
        title={workingDir}
        className="hover:bg-accent text-muted-foreground flex items-center gap-1.5 rounded-md px-2 py-1 text-xs transition-colors"
      >
        <FolderIcon className="size-3.5 shrink-0" />
        <span className="text-foreground min-w-0 flex-1 truncate text-start font-medium">{base}</span>
        <ChevronDownIcon className="size-3 shrink-0 opacity-60" />
      </button>
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
    </div>
  );
};
