import { describe, it, expect } from "vitest";
import { TOOL_UI_BY_NAME } from "./registry";
import { AskUserQuestionToolUI } from "./ask-user-question-tool";
import { GenerativePromptToolUI } from "./generative-prompt-tool";

describe("tool-ui registry", () => {
  it("registers AskUserQuestion → AskUserQuestionToolUI", () => {
    expect(TOOL_UI_BY_NAME.AskUserQuestion).toBe(AskUserQuestionToolUI);
  });
  it("registers PromptUser → GenerativePromptToolUI (Plan 47 B)", () => {
    expect(TOOL_UI_BY_NAME.PromptUser).toBe(GenerativePromptToolUI);
  });
  it("has no entry for unregistered tools (falls back)", () => {
    expect(TOOL_UI_BY_NAME.Bash).toBeUndefined();
    expect(TOOL_UI_BY_NAME.Edit).toBeUndefined();
  });
});
