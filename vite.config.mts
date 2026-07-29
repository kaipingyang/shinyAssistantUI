import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { visualizer } from "rollup-plugin-visualizer";
import { resolve } from "path";
import { writeFileSync, mkdirSync, copyFileSync, readdirSync } from "fs";

export default defineConfig({
  resolve: {
    alias: { "@": resolve(import.meta.dirname, "srcjs") },
  },
  plugins: [
    react(),
    tailwindcss(),
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

        // Plan 34 (fix): bundle KaTeX CSS + woff2 fonts LOCALLY into inst/www/katex/ so LaTeX
        // renders from same-origin assets (no CDN → no font-load reflow / "忽大忽小", offline-ok).
        // Only woff2 is copied: KaTeX @font-face lists woff2 first, so browsers never request
        // the woff/ttf fallbacks. Served on demand via an htmlDependency attached when latex=TRUE.
        const katexSrc = "node_modules/katex/dist";
        mkdirSync("inst/www/katex/fonts", { recursive: true });
        copyFileSync(`${katexSrc}/katex.min.css`, "inst/www/katex/katex.min.css");
        for (const f of readdirSync(`${katexSrc}/fonts`)) {
          if (f.endsWith(".woff2")) {
            copyFileSync(`${katexSrc}/fonts/${f}`, `inst/www/katex/fonts/${f}`);
          }
        }
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
    // 构建期产出 bundle 构成报告（treemap，含 gzip/brotli 尺寸）。仅 build 期，
    // 不进运行时 bundle；产物 gitignore。用于评估"哪些依赖占体积"。
    visualizer({
      filename: "inst/www/bundle-stats.html",
      title: "shinyAssistantUI bundle",
      gzipSize: true,
      brotliSize: true,
    }),
  ],
  define: {
    "process.env.NODE_ENV": JSON.stringify("production"),
  },
  build: {
    lib: {
      entry: resolve(import.meta.dirname, "srcjs/index.tsx"),
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
