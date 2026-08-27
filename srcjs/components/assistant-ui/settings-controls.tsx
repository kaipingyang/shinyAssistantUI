import { useEffect, useId, useRef, useState } from "react";
import { SettingsIcon, XIcon } from "lucide-react";
import { useShinyConfig } from "../../shiny-config-context";
import { ModelSelector } from "@/components/assistant-ui/model-selector";
import type {
  AssistantTextSize,
  PermissionModeOption,
} from "../../shiny-config-context";

// 危险模式可见性过滤(Plan 45):关掉 Show Bypass/YOLO 时从选择器隐藏对应项,
// 但【当前选中值】永不隐藏(否则 select 显示错乱)。
function visibleModeOptions(
  options: PermissionModeOption[],
  visibility: { showBypass: boolean; showYolo: boolean } | undefined,
  currentValue?: string,
): PermissionModeOption[] {
  if (!visibility) return options;
  return options.filter(
    (o) =>
      (o.value !== "bypassPermissions" || visibility.showBypass || o.value === currentValue) &&
      (o.value !== "yolo" || visibility.showYolo || o.value === currentValue),
  );
}

export function PermissionModeControl({ compact = false }: { compact?: boolean }) {
  const { permissionMode, modeVisibility } = useShinyConfig();
  const selectId = useId();
  if (!permissionMode) return null;

  const opts = visibleModeOptions(permissionMode.options, modeVisibility, permissionMode.value);
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
        {opts.map((option) => (
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
  const requestedLabel = model.options.find((option) => option.value === model.requested)?.label
    ?? model.requested;
  return (
    <div
      data-slot="aui_model_control"
      data-pending={model.pending ? "true" : "false"}
      className="flex items-center gap-1.5"
    >
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
      {model.pending && (
        <span data-slot="aui_model_pending" role="status" className="text-muted-foreground text-[11px]">
          Applying {requestedLabel || "model"}…
        </span>
      )}
      {!model.pending && model.error && (
        <span data-slot="aui_model_error" role="alert" className="text-destructive text-[11px]" title={model.error}>
          Model change failed
        </span>
      )}
    </div>
  );
}

// Plan 45:新会话默认权限模式(持久化偏好,和 composer 内联的"本会话即时切换"不同)。
function DefaultModeControl() {
  const { permissionMode, defaultPermissionMode, setDefaultPermissionMode, modeVisibility } = useShinyConfig();
  const selectId = useId();
  if (!permissionMode || defaultPermissionMode === undefined || !setDefaultPermissionMode) return null;
  const opts = visibleModeOptions(permissionMode.options, modeVisibility, defaultPermissionMode);
  const selected = permissionMode.options.find((o) => o.value === defaultPermissionMode);
  return (
    <div className="aui-default-mode space-y-1.5">
      <div>
        <label className="text-foreground text-xs font-medium" htmlFor={selectId}>New-conversation default</label>
        <p className="text-muted-foreground mt-0.5 text-[11px] leading-4">
          {selected?.description ?? "Permission mode new conversations start in."}
        </p>
      </div>
      <select
        id={selectId}
        aria-label="Default permission mode"
        data-slot="aui_default_permission_mode"
        className="border-input bg-background text-foreground h-8 w-full rounded-md border px-2 text-xs outline-none focus:ring-1 focus:ring-ring"
        value={defaultPermissionMode}
        onChange={(e) => setDefaultPermissionMode(e.target.value)}
      >
        {opts.map((o) => (
          <option key={o.value} value={o.value} disabled={o.disabled}>{o.label}</option>
        ))}
      </select>
    </div>
  );
}

// Plan 45:危险模式可见性 —— 关掉后 Bypass/YOLO 不出现在选择器(受限环境防误触)。
function ModeVisibilityControl() {
  const { modeVisibility, setModeVisibility } = useShinyConfig();
  if (!modeVisibility || !setModeVisibility) return null;
  const row = (label: string, key: "showBypass" | "showYolo") => (
    <label className="flex cursor-pointer items-center gap-2 text-xs" data-mode-vis={key}>
      <input
        type="checkbox"
        checked={modeVisibility[key]}
        onChange={(e) => setModeVisibility({ ...modeVisibility, [key]: e.target.checked })}
      />
      <span>{label}</span>
    </label>
  );
  return (
    <div className="aui-mode-visibility mt-3 space-y-1.5">
      <div>
        <span className="text-foreground text-xs font-medium">Available modes</span>
        <p className="text-muted-foreground mt-0.5 text-[11px] leading-4">
          Show these risky modes in the mode selector.
        </p>
      </div>
      {row("Show Bypass", "showBypass")}
      {row("Show YOLO", "showYolo")}
    </div>
  );
}

// Plan 45:输入框高度两档(Compact 扁平 ≈ shinychat / Comfortable 现状),只改起始高度。
function ComposerDensityControl() {
  const { composerDensity, setComposerDensity } = useShinyConfig();
  const selectId = useId();
  if (composerDensity === undefined || !setComposerDensity) return null;
  return (
    <div className="aui-composer-density mt-3 space-y-1.5">
      <div>
        <label htmlFor={selectId} className="text-foreground text-xs font-medium">Composer height</label>
        <p className="text-muted-foreground mt-0.5 text-[11px] leading-4">
          Compact keeps a flat single-line input (grows as you type).
        </p>
      </div>
      <select
        id={selectId}
        aria-label="Composer height"
        data-slot="aui_composer_density"
        className="border-input bg-background text-foreground h-8 w-full rounded-md border px-2 text-xs outline-none focus:ring-1 focus:ring-ring"
        value={composerDensity}
        onChange={(e) => setComposerDensity(e.target.value === "compact" ? "compact" : "comfortable")}
      >
        <option value="comfortable">Comfortable</option>
        <option value="compact">Compact</option>
      </select>
    </div>
  );
}

function AssistantTextSizeControl() {
  const { assistantTextSize, setAssistantTextSize } = useShinyConfig();
  const selectId = useId();
  if (assistantTextSize === undefined || !setAssistantTextSize) return null;
  return (
    <div className="aui-assistant-text-size mt-3 space-y-1.5">
      <div>
        <label htmlFor={selectId} className="text-foreground text-xs font-medium">
          Assistant text size
        </label>
        <p className="text-muted-foreground mt-0.5 text-[11px] leading-4">
          Smaller text shows more of each response on compact screens.
        </p>
      </div>
      <select
        id={selectId}
        aria-label="Assistant text size"
        data-slot="aui_assistant_text_size"
        className="border-input bg-background text-foreground h-8 w-full rounded-md border px-2 text-xs outline-none focus:ring-1 focus:ring-ring"
        value={assistantTextSize}
        onChange={(event) => setAssistantTextSize(event.target.value as AssistantTextSize)}
      >
        <option value="small">Small</option>
        <option value="compact">Medium</option>
        <option value="medium">Default</option>
      </select>
    </div>
  );
}

// Plan 45:run_r MCP 工具开关(默认开;关掉后 Claude 无法在你的 R 会话执行代码)。
function RunRToggle() {
  const { runREnabled, setRunREnabled } = useShinyConfig();
  if (runREnabled === undefined || !setRunREnabled) return null;
  return (
    <label className="aui-run-r-toggle mt-3 flex cursor-pointer items-center gap-2 text-xs" data-slot="aui_run_r_toggle">
      <input
        type="checkbox"
        checked={runREnabled}
        onChange={(e) => setRunREnabled(e.target.checked)}
      />
      <span className="text-foreground font-medium">Enable R console tool (run_r)</span>
    </label>
  );
}

function CopilotAutoStartToggle() {
  const { autoStartCopilotApi, setAutoStartCopilotApi } = useShinyConfig();
  if (autoStartCopilotApi === undefined || !setAutoStartCopilotApi) return null;
  return (
    <label
      className="aui-copilot-auto-start mt-3 flex cursor-pointer items-center gap-2 text-xs"
      data-slot="aui_copilot_auto_start"
    >
      <input
        type="checkbox"
        checked={autoStartCopilotApi}
        onChange={(event) => setAutoStartCopilotApi(event.target.checked)}
      />
      <span className="text-foreground font-medium">Automatically start copilot-api</span>
    </label>
  );
}

export function SidebarSettings() {
  const {
    permissionMode,
    thinking,
    composerDensity,
    assistantTextSize,
    autoStartCopilotApi,
  } = useShinyConfig();
  const [open, setOpen] = useState(false);
  const dialogId = useId();
  const dialogRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (open) dialogRef.current?.focus();
  }, [open]);

  if (!permissionMode && !thinking && composerDensity === undefined &&
      assistantTextSize === undefined && autoStartCopilotApi === undefined) return null;
  const close = () => {
    setOpen(false);
    triggerRef.current?.focus();
  };

  return (
    <div className="aui-sidebar-settings shrink-0 border-t pt-2">
      {open && (
        <div
          ref={dialogRef}
          id={dialogId}
          role="dialog"
          aria-label="Settings"
          data-slot="aui_settings_dialog"
          tabIndex={-1}
          onKeyDown={(event) => {
            if (event.key === "Escape") {
              event.preventDefault();
              close();
            }
          }}
          className="bg-popover text-popover-foreground absolute inset-x-2 bottom-12 z-20 max-h-[calc(100%-4rem)] w-auto overflow-y-auto overscroll-contain rounded-lg border p-3 shadow-lg outline-none [scrollbar-gutter:stable]"
        >
          <div
            data-slot="aui_settings_header"
            className="bg-popover sticky top-0 z-10 mb-3 flex items-center justify-between"
          >
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
          <DefaultModeControl />
          <ModeVisibilityControl />
          <ThinkingControl />
          <ComposerDensityControl />
          <AssistantTextSizeControl />
          <RunRToggle />
          <CopilotAutoStartToggle />
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
