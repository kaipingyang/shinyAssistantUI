import type { FC } from "react";
import type { SyntaxHighlighterProps } from "@assistant-ui/react-markdown";
import { PrismLight } from "react-syntax-highlighter";

import tsx from "react-syntax-highlighter/dist/esm/languages/prism/tsx";
import typescript from "react-syntax-highlighter/dist/esm/languages/prism/typescript";
import javascript from "react-syntax-highlighter/dist/esm/languages/prism/javascript";
import python from "react-syntax-highlighter/dist/esm/languages/prism/python";
import r from "react-syntax-highlighter/dist/esm/languages/prism/r";
import bash from "react-syntax-highlighter/dist/esm/languages/prism/bash";
import json from "react-syntax-highlighter/dist/esm/languages/prism/json";
import yaml from "react-syntax-highlighter/dist/esm/languages/prism/yaml";
import sql from "react-syntax-highlighter/dist/esm/languages/prism/sql";
import markdown from "react-syntax-highlighter/dist/esm/languages/prism/markdown";
import css from "react-syntax-highlighter/dist/esm/languages/prism/css";

import { oneLight } from "react-syntax-highlighter/dist/esm/styles/prism";

// 助手消息代码块的语法高亮。直接渲染 PrismLight（同步、只打包下面显式注册的语言），
// 刻意不走 @assistant-ui/react-syntax-highlighter 的 make* 工厂——它会把完整
// react-syntax-highlighter（约 200 种语言）拉进单 IIFE bundle 使体积翻倍。
// 与工具结果卡（shiny-tool-result.tsx）统一用 PrismLight + oneLight。
PrismLight.registerLanguage("r", r);
PrismLight.registerLanguage("rscript", r);
PrismLight.registerLanguage("python", python);
PrismLight.registerLanguage("py", python);
PrismLight.registerLanguage("bash", bash);
PrismLight.registerLanguage("sh", bash);
PrismLight.registerLanguage("shell", bash);
PrismLight.registerLanguage("json", json);
PrismLight.registerLanguage("yaml", yaml);
PrismLight.registerLanguage("yml", yaml);
PrismLight.registerLanguage("sql", sql);
PrismLight.registerLanguage("markdown", markdown);
PrismLight.registerLanguage("md", markdown);
PrismLight.registerLanguage("css", css);
PrismLight.registerLanguage("javascript", javascript);
PrismLight.registerLanguage("js", javascript);
PrismLight.registerLanguage("typescript", typescript);
PrismLight.registerLanguage("ts", typescript);
PrismLight.registerLanguage("tsx", tsx);
PrismLight.registerLanguage("jsx", tsx);

// R 优先：assistant-ui 对无语言标签的代码围栏会传 "unknown"（空亦然）。本 addin 面向 R，
// 把这类未标注代码块按 R 处理——既给出合理的语言标签，也用 R 语法高亮（R 项目里绝大多数
// 无标签代码块就是 R）。显式指定的语言（python/bash/json…）原样保留。
export function resolveCodeLanguage(language?: string): string {
  const lang = (language ?? "").trim();
  // Unknown / language-less fences: treat as markdown (neutral) rather than
  // forcing R — avoids mislabelling plain text/output as R code.
  return !lang || lang.toLowerCase() === "unknown" ? "markdown" : lang;
}

export const SyntaxHighlighter: FC<SyntaxHighlighterProps> = ({ language, code }) => {
  return (
    <PrismLight
      language={resolveCodeLanguage(language)}
      style={oneLight}
      className="aui-syntax-highlighter [&_.token]:inline"
      data-syntax-highlighter="prism"
      customStyle={{
        margin: 0,
        width: "100%",
        background: "transparent",
        padding: 0,
        fontSize: "13px",
      }}
    >
      {code}
    </PrismLight>
  );
};

// 工具参数 JSON 高亮（缩进后的对象）——复用 PrismLight + json（已注册）+ oneLight。
export const JsonHighlighter: FC<{ code: string }> = ({ code }) => (
  <PrismLight
    language="json"
    style={oneLight}
    data-syntax-highlighter="prism-json"
    customStyle={{
      margin: 0,
      width: "100%",
      background: "transparent",
      padding: 0,
      fontSize: "12px",
    }}
  >
    {code}
  </PrismLight>
);
