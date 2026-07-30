import { useEffect, useId, useRef, useState } from "react";
import { SettingsIcon, XIcon } from "lucide-react";
import { useShinyConfig } from "../../shiny-config-context";
import { ModelSelector } from "@/components/assistant-ui/model-selector";

export function PermissionModeControl({ compact = false }: { compact?: boolean }) {
  const { permissionMode } = useShinyConfig();
  const selectId = useId();
  if (!permissionMode) return null;

  const selected = permissionMode.options.find((option) => option.value === permissionMode.value);
  return (
    <div className={compact ? "aui-permission-mode flex min-w-0 items-center" : "aui-permission-mode space-y-1.5"}>
      {!compact && (
        <div>
          <label className="text-foreground text-xs font-medium" htmlFor={selectId}>
            Permission mode
          </label>
          <p className="text-muted-foreground mt-0.5 text-[11px] leading-4">
            {selected?.description ?? "Controls how the assistant may modify your project."}
          </p>
        </div>
      )}
      <select
        id={selectId}
        aria-label="Permission mode"
        className={compact
          ? "border-input bg-background text-foreground h-7 max-w-32 rounded-md border px-2 text-xs outline-none focus:ring-1 focus:ring-ring disabled:opacity-60"
          : "border-input bg-background text-foreground h-8 w-full rounded-md border px-2 text-xs outline-none focus:ring-1 focus:ring-ring disabled:opacity-60"}
        value={permissionMode.value}
        disabled={permissionMode.pending}
        title={permissionMode.error ?? selected?.description}
        onChange={(event) => permissionMode.setValue(event.target.value)}
      >
        {permissionMode.options.map((option) => (
          <option key={option.value} value={option.value} disabled={option.disabled}>
            {option.label}
          </option>
        ))}
      </select>
      {permissionMode.pending && (
        <span className="text-muted-foreground ml-1 text-[10px]" aria-live="polite">Submitting...</span>
      )}
      {permissionMode.error && !compact && (
        <p className="text-destructive text-[11px]" role="alert">{permissionMode.error}</p>
      )}
    </div>
  );
}

export function ThinkingControl() {
  const { thinking } = useShinyConfig();
  const selectId = useId();
  if (!thinking) return null;
  const selected = thinking.options.find((o) => o.value === thinking.value);
  return (
    <div className="aui-thinking-mode mt-3 space-y-1.5">
      <div>
        <label className="text-foreground text-xs font-medium" htmlFor={selectId}>
          Thinking
        </label>
        <p className="text-muted-foreground mt-0.5 text-[11px] leading-4">
          {selected?.description ?? "How much the assistant thinks before responding."}
        </p>
      </div>
      <select
        id={selectId}
        aria-label="Thinking level"
        className="border-input bg-background text-foreground h-8 w-full rounded-md border px-2 text-xs outline-none focus:ring-1 focus:ring-ring"
        value={thinking.value}
        title={selected?.description}
        onChange={(event) => thinking.setValue(event.target.value)}
      >
        {thinking.options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
    </div>
  );
}

// `/model` 命令触发的模型选择器弹窗（选中即 set_model，热切换）。由 runtime 的
// model.pickerOpen 控制显隐；渲染在 composer 附近（见 thread.tsx）。
export function ModelPickerDialog() {
  const { model } = useShinyConfig();
  if (!model) return null;
  // 用官方 @assistant-ui ModelSelector(base-ui)渲染,喂 R 的 model 配置。保留 /model 命令触发
  // (受控 open=pickerOpen);trigger 常驻显示当前模型(相比旧的纯命令弹窗,多了一个可见入口)。
  const models = model.options.map((o) => ({
    id: o.value,
    name: o.label,
    ...(o.description ? { description: o.description } : {}),
    ...(o.disabled ? { disabled: true } : {}),
  }));
  return (
    <ModelSelector
      models={models}
      value={model.value}
      onValueChange={(v) => model.setValue(v)}
      open={model.pickerOpen}
      onOpenChange={model.setPickerOpen}
      searchable={models.length > 8}
      variant="ghost"
      size="sm"
    />
  );
}

export function SidebarSettings() {
  const { permissionMode, thinking } = useShinyConfig();
  const [open, setOpen] = useState(false);
  const dialogId = useId();
  const dialogRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (open) dialogRef.current?.focus();
  }, [open]);

  if (!permissionMode && !thinking) return null;
  const close = () => {
    setOpen(false);
    triggerRef.current?.focus();
  };

  return (
    <div className="aui-sidebar-settings relative border-t pt-2">
      {open && (
        <div
          ref={dialogRef}
          id={dialogId}
          role="dialog"
          aria-label="Settings"
          tabIndex={-1}
          onKeyDown={(event) => {
            if (event.key === "Escape") {
              event.preventDefault();
              close();
            }
          }}
          className="bg-popover text-popover-foreground absolute inset-x-0 bottom-full z-20 mb-2 w-auto rounded-lg border p-3 shadow-lg outline-none"
        >
          <div className="mb-3 flex items-center justify-between">
            <h2 className="text-sm font-semibold">Settings</h2>
            <button
              type="button"
              className="hover:bg-accent rounded p-1"
              aria-label="Close settings"
              onClick={close}
            >
              <XIcon className="size-3.5" />
            </button>
          </div>
          <PermissionModeControl />
          <ThinkingControl />
          <p className="text-muted-foreground mt-3 text-[10px] leading-4">
            Changes are submitted to the backend for this conversation.
          </p>
        </div>
      )}
      <button
        ref={triggerRef}
        type="button"
        className="text-muted-foreground hover:bg-accent hover:text-accent-foreground flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-xs"
        aria-label="Settings"
        aria-expanded={open}
        aria-controls={dialogId}
        onClick={() => open ? close() : setOpen(true)}
      >
        <SettingsIcon className="size-3.5" />
        <span>Settings</span>
      </button>
    </div>
  );
}
