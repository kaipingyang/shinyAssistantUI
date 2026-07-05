import { createContext, useContext } from "react";

export interface ShinyCommand { name: string; description?: string; prompt: string; }
export interface ShinyToolItem { name: string; description?: string; }

export interface ShinyConfigCtx {
  tools: ShinyToolItem[];
  commands: ShinyCommand[];
  showTimestamps: boolean;
  onEnqueue: (text: string) => void;
  onRename: (threadId: string, title: string) => void;
}

export const ShinyConfigContext = createContext<ShinyConfigCtx>({
  tools: [],
  commands: [],
  showTimestamps: false,
  onEnqueue: () => {},
  onRename: () => {},
});

export const useShinyConfig = () => useContext(ShinyConfigContext);
