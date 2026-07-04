import React from "react";
import ReactDOM from "react-dom/client";
import AssistantUI from "./AssistantUI";
import { createRemovalWatcher, themeToCssVars } from "./helpers";
import { ErrorBoundary } from "./error-boundary";

// @ts-ignore — HTMLWidgets is loaded globally by Shiny
declare const HTMLWidgets: {
  widget: (def: {
    name: string;
    type: string;
    factory: (
      el: HTMLElement,
      width: number,
      height: number
    ) => {
      renderValue: (x: { inputId: string; config: Record<string, unknown> }) => void;
      resize: (width: number, height: number) => void;
    };
  }) => void;
};

HTMLWidgets.widget({
  name: "assistantUI",
  type: "output",

  factory(el, _width, _height) {
    let root: ReturnType<typeof ReactDOM.createRoot> | null = null;
    let renderCount = 0;
    let disconnectWatcher: (() => void) | null = null;
    let mqCleanup: (() => void) | null = null;

    // 主题注入:把 config.theme 的 token 写成 el 的 inline CSS 变量（scoped 到本 widget），
    // 并按 config.dark_mode 切换 `dark` 类（"auto" 跟随系统 prefers-color-scheme）。
    const applyTheme = (config: Record<string, unknown>) => {
      // 先清上一次的 matchMedia 监听,避免重渲染累积
      if (mqCleanup) { mqCleanup(); mqCleanup = null; }

      const vars = themeToCssVars(config?.theme as Record<string, unknown> | undefined);
      for (const [cssVar, value] of vars) el.style.setProperty(cssVar, value);

      const dm = config?.dark_mode;
      if (dm === "auto") {
        const mq = window.matchMedia("(prefers-color-scheme: dark)");
        const sync = () => el.classList.toggle("dark", mq.matches);
        sync();
        mq.addEventListener("change", sync);
        mqCleanup = () => mq.removeEventListener("change", sync);
      } else {
        el.classList.toggle("dark", dm === true);
      }
    };

    // 卸载 React 树释放资源，避免孤儿 root 累积（el 从 DOM 移除时调用）。
    const teardown = () => {
      if (root) {
        try { root.unmount(); } catch { /* already unmounted */ }
        root = null;
      }
      if (disconnectWatcher) { disconnectWatcher(); disconnectWatcher = null; }
      if (mqCleanup) { mqCleanup(); mqCleanup = null; }
    };

    return {
      renderValue(x) {
        if (!root) {
          el.style.height = "100%";
          el.style.minHeight = "400px";
          root = ReactDOM.createRoot(el);
          disconnectWatcher = createRemovalWatcher(el, teardown);
        }
        applyTheme(x.config ?? {});
        renderCount += 1;
        root.render(
          <ErrorBoundary resetKey={renderCount}>
            <AssistantUI inputId={x.inputId} config={x.config ?? {}} />
          </ErrorBoundary>
        );
      },
      resize(_width, _height) {
        // Layout handled by CSS
      },
    };
  },
});
