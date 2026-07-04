import React from "react";

// 捕获 React 渲染错误，显示降级 UI。resetKey 变化时清除错误态，
// 避免一次瞬时错误后 widget 永久卡在错误 UI、新数据无法恢复。
export class ErrorBoundary extends React.Component<
  { children: React.ReactNode; resetKey?: unknown },
  { error: Error | null }
> {
  constructor(props: { children: React.ReactNode; resetKey?: unknown }) {
    super(props);
    this.state = { error: null };
  }
  static getDerivedStateFromError(error: Error) {
    return { error };
  }
  componentDidUpdate(prevProps: { resetKey?: unknown }) {
    if (this.state.error && prevProps.resetKey !== this.props.resetKey) {
      this.setState({ error: null });
    }
  }
  render() {
    if (this.state.error) {
      const e = this.state.error;
      return (
        <div style={{ padding: "1rem", color: "red", fontFamily: "monospace", fontSize: "12px", border: "1px solid red" }}>
          <strong>AssistantUI Error:</strong>
          <pre style={{ whiteSpace: "pre-wrap" }}>{String(e)}</pre>
          <pre style={{ whiteSpace: "pre-wrap" }}>{e?.stack ?? "(no stack)"}</pre>
          <pre style={{ whiteSpace: "pre-wrap" }}>{JSON.stringify(e, Object.getOwnPropertyNames(e))}</pre>
        </div>
      );
    }
    return this.props.children;
  }
}
