// Plan 36: subscribe to the per-thread agent state pushed from R via on_state().
import type { FC } from "react";
import { useShinyConfig } from "@/shiny-config-context";

/** Read the current thread's agent state (whatever R pushed via `on_state(list(...))`). */
export function useShinyAgentState<T = Record<string, unknown>>(): T | undefined {
  return useShinyConfig().agentState as T | undefined;
}

/** Read a derived value from the agent state. */
export function useShinyAgentStateSelector<T>(
  selector: (state: Record<string, unknown> | undefined) => T,
): T {
  return selector(useShinyConfig().agentState as Record<string, unknown> | undefined);
}

// Built-in optional progress indicator: renders when agentState.progress is a number (0–1),
// e.g. R loops over files calling on_state(list(progress = i/n, current = f)).
export const ShinyAgentProgress: FC = () => {
  const state = useShinyAgentState<{ progress?: number; current?: string; status?: string }>();
  const progress = typeof state?.progress === "number" ? state.progress : undefined;
  if (progress === undefined) return null;
  const pct = Math.max(0, Math.min(1, progress)) * 100;
  return (
    <div data-slot="agent-progress" className="aui-agent-progress flex items-center gap-2 px-2 py-1 text-xs">
      <div className="bg-muted h-1.5 flex-1 overflow-hidden rounded-full">
        <div
          data-agent-progress-bar
          className="bg-primary h-full rounded-full transition-all duration-300"
          style={{ width: `${pct}%` }}
        />
      </div>
      <span className="text-muted-foreground tabular-nums" data-agent-progress-pct>
        {Math.round(pct)}%
      </span>
      {state?.current ? (
        <span className="text-muted-foreground max-w-[12rem] truncate" data-agent-progress-current>
          {state.current}
        </span>
      ) : null}
    </div>
  );
};
