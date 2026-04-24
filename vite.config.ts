import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { resolve } from "path";
import { writeFileSync } from "fs";

export default defineConfig({
  plugins: [
    react(),
    // @assistant-ui/tap 生产模式下 tapEffectEvent 直接返回 callbackRef.current（陈旧回调），
    // 导致 handleKeyDown 内 open 捕获的是上一帧的 false，键盘导航完全失效。
    // 开发模式返回稳定包装函数（每次调用最新 callback），行为正确。
    // 此插件强制 tap 库走开发模式路径，不影响 React 自身的 production build。
    {
      name: "bump-widget-version",
      closeBundle() {
        const version = `0.0.${Math.floor(Date.now() / 60000)}`;
        const yaml = `dependencies:\n  - name: shinyAssistantUI\n    version: ${version}\n    src: www\n    script: shinyAssistantUI.js\n    stylesheet: style.css\n`;
        writeFileSync("inst/htmlwidgets/assistantUI.yaml", yaml);
      },
    },
    {
      name: "patch-tap-is-development",
      transform(code: string, id: string) {
        if (id.includes("@assistant-ui/tap") && id.endsWith("/env.js")) {
          return { code: "export const isDevelopment = true;\n", map: null };
        }
      },
    },
  ],
  define: {
    "process.env.NODE_ENV": JSON.stringify("production"),
  },
  build: {
    lib: {
      entry: resolve(__dirname, "srcjs/index.tsx"),
      name: "shinyAssistantUI",
      formats: ["iife"],
      fileName: () => "shinyAssistantUI.js",
    },
    outDir: "inst/www",
    emptyOutDir: false,
    rollupOptions: {
      output: {
        // Inline all assets (CSS) into the JS bundle
        inlineDynamicImports: true,
      },
    },
  },
});
