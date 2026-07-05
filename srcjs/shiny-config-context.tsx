import { createContext, useContext } from "react";

export interface ShinyCommand { name: string; description?: string; prompt: string; }
export interface ShinyToolItem { name: string; description?: string; }
export interface ShinyActionItem { section?: string; id: string; label?: string; description?: string; }

export interface ShinyConfigCtx {
  tools: ShinyToolItem[];
  commands: ShinyCommand[];
  actionItems: ShinyActionItem[];
  showTimestamps: boolean;
  onEnqueue: (text: string) => void;
  onRename: (threadId: string, title: string) => void;
  onInvokeAction: (item: ShinyActionItem) => void;
}

export const ShinyConfigContext = createContext<ShinyConfigCtx>({
  tools: [],
  commands: [],
  actionItems: [],
  showTimestamps: false,
  onEnqueue: () => {},
  onRename: () => {},
  onInvokeAction: () => {},
});

export const useShinyConfig = () => useContext(ShinyConfigContext);
