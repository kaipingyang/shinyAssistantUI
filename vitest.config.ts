import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  test: {
    // 只跑本项目 srcjs 下的测试，排除 node_modules 里 @assistant-ui 源码自带的测试
    include: ["srcjs/**/*.test.{ts,tsx}"],
    // 默认 node 环境；DOM 测试文件用顶部 `// @vitest-environment jsdom` 注释覆盖
    environment: "node",
  },
});
