import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { visualizer } from "rollup-plugin-visualizer";
import { resolve } from "path";
import { writeFileSync, mkdirSync, copyFileSync, readdirSync, readFileSync } from "fs";

const description = readFileSync(resolve(import.meta.dirname, "DESCRIPTION"), "utf8");
const widgetVersion = description.match(/^Version:\s*(\S+)\s*$/m)?.[1];
if (!widgetVersion) throw new Error("DESCRIPTION has no Version field");

export function deferAssistantViewportResize(
  code: string, id: string,
): { code: string; map: null } | null {
  if (!id.endsWith("/@assistant-ui/react/dist/utils/hooks/useOnResizeContent.js")) return null;
  const resize = /const resizeObserver = new ResizeObserver\(\(\) => \{\s*callbackRef\(\);\s*\}\);/g;
  const cleanup = /return \(\) => \{\s*resizeObserver\.disconnect\(\);\s*mutationObserver\.disconnect\(\);\s*\};/g;
  if ([...code.matchAll(resize)].length !== 1 || [...code.matchAll(cleanup)].length !== 1 ||
      /\bresizeFrame\b/.test(code)) {
    throw new Error("assistant-ui viewport resize hook changed; re-evaluate the deferred resize compatibility transform");
  }
  // Viewport state changes must not resize observed ancestors in the same delivery cycle.
  return {
    code: code.replace(resize, `let resizeFrame = null;
      const resizeObserver = new ResizeObserver(() => {
        if (resizeFrame !== null) return;
        resizeFrame = requestAnimationFrame(() => {
          resizeFrame = null;
          callbackRef();
        });
      });`).replace(cleanup, `return () => {
        resizeObserver.disconnect();
        mutationObserver.disconnect();
        if (resizeFrame !== null) {
          cancelAnimationFrame(resizeFrame);
          resizeFrame = null;
        }
      };`),
    map: null,
  };
}

export function inlineGenerativeUiNodeEnv(
  code: string, id: string,
): { code: string; map: null } | null {
  if (!id.includes("/node_modules/@assistant-ui/react-generative-ui/")) return null;
  const next = code
    .replaceAll('process.env["NODE_ENV"]', '"production"')
    .replaceAll("process.env['NODE_ENV']", '"production"');
  return next === code ? null : { code: next, map: null };
}

export default defineConfig({
  resolve: {
    alias: { "@": resolve(import.meta.dirname, "srcjs") },
  },
  plugins: [
    react(),
    tailwindcss(),
    {
      name: "inline-generative-ui-node-env",
      transform: inlineGenerativeUiNodeEnv,
    },
    {
      name: "defer-assistant-viewport-resize",
      transform: deferAssistantViewportResize,
    },
    {
      name: "bump-widget-version",
      closeBundle() {
        const yaml = `dependencies:\n  - name: shinyAssistantUI\n    version: ${widgetVersion}\n    src: www\n    script: shinyAssistantUI.js\n    stylesheet: style.css\n`;
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
    // 默认排除 devtools;`AUI_DEVTOOLS=1 npm run build` 打包含 devtools 的调试版。
    __AUI_DEVTOOLS__: process.env.AUI_DEVTOOLS === "1" ? "true" : "false",
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
