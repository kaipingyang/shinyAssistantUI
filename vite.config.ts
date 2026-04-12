import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { resolve } from "path";

export default defineConfig({
  plugins: [react()],
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
