import React from "react";
import ReactDOM from "react-dom/client";
import "./globals.css";
import AssistantUI from "./AssistantUI";
import { createRemovalWatcher, themeToCssVars } from "./helpers";
import { ErrorBoundary } from "./error-boundary";

// P1(组件形态,dev):从 htmlwidget 迁移到原生 Shiny OutputBinding + HTMLDependency
// (对齐 shinychat)。挂载点是普通 <div class="assistantUI assistantUI-output">;R 侧
// 通过 htmlDependency 提供本 JS/CSS,通过 createRenderFunction 下发 {inputId, config}。
// 所有实时双向流量仍走 bridge 的 Shiny.addCustomMessageHandler / setInputValue(不变)。

// eslint-disable-next-line @typescript-eslint/no-explicit-any
declare const Shiny: any;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
declare const $: any;

type RenderData = { inputId: string; config: Record<string, unknown> };

type MountState = {
  root: ReturnType<typeof ReactDOM.createRoot> | null;
  renderCount: number;
  disconnect: (() => void) | null;
  mqCleanup: (() => void) | null;
};
const _mounts = new WeakMap<HTMLElement, MountState>();

// 主题注入:把 config.theme 的 token 写成 el 的 inline CSS 变量(scoped 到本实例),
// 并按 config.dark_mode 切换 `dark` 类("auto" 跟随系统)。
const applyTheme = (el: HTMLElement, st: MountState, config: Record<string, unknown>) => {
  if (st.mqCleanup) { st.mqCleanup(); st.mqCleanup = null; }
  const vars = themeToCssVars(config?.theme as Record<string, unknown> | undefined);
  for (const [cssVar, value] of vars) el.style.setProperty(cssVar, value);
  const dm = config?.dark_mode;
  if (dm === "auto") {
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const sync = () => el.classList.toggle("dark", mq.matches);
    sync();
    mq.addEventListener("change", sync);
    st.mqCleanup = () => mq.removeEventListener("change", sync);
  } else {
    el.classList.toggle("dark", dm === true);
  }
};

const teardown = (el: HTMLElement) => {
  const st = _mounts.get(el);
  if (!st) return;
  if (st.root) { try { st.root.unmount(); } catch { /* already unmounted */ } st.root = null; }
  if (st.disconnect) { st.disconnect(); st.disconnect = null; }
  if (st.mqCleanup) { st.mqCleanup(); st.mqCleanup = null; }
  _mounts.delete(el);
};

const mount = (el: HTMLElement, data: RenderData) => {
  if (!data || typeof data.inputId !== "string") return;
  let st = _mounts.get(el);
  if (!st) {
    st = { root: null, renderCount: 0, disconnect: null, mqCleanup: null };
    _mounts.set(el, st);
  }
  if (!st.root) {
    el.style.height = "100%";
    el.style.minHeight = "400px";
    st.root = ReactDOM.createRoot(el);
    st.disconnect = createRemovalWatcher(el, () => teardown(el));
  }
  const config = data.config ?? {};
  applyTheme(el, st, config);
  st.renderCount += 1;
  st.root.render(
    <ErrorBoundary resetKey={st.renderCount}>
      <AssistantUI inputId={data.inputId} config={config} />
    </ErrorBoundary>
  );
};

class AssistantUIOutputBinding extends Shiny.OutputBinding {
  find(scope: HTMLElement) {
    return $(scope).find(".assistantUI-output");
  }
  renderValue(el: HTMLElement, data: RenderData) {
    mount(el, data);
  }
  // 输出错误时不清空 React 树(保持已挂载 UI);Shiny 默认会加 recalculating 类。
  renderError() { /* no-op: errors surfaced via bridge on_error */ }
  clearError() { /* no-op */ }
}

Shiny.outputBindings.register(new AssistantUIOutputBinding(), "shinyAssistantUI.assistantUIOutput");
