import { useEffect, useId, useRef, useState } from "react";
import { SettingsIcon, XIcon } from "lucide-react";
import { useShinyConfig } from "../../shiny-config-context";

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

export function SidebarSettings() {
  const { permissionMode } = useShinyConfig();
  const [open, setOpen] = useState(false);
  const dialogId = useId();
  const dialogRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (open) dialogRef.current?.focus();
  }, [open]);

  if (!permissionMode) return null;
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
