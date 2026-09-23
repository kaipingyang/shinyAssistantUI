type SearchableThread = {
  id: string;
  title?: string;
  custom?: Readonly<Record<string, unknown>>;
};

export const normalizeThreadSearch = (text: string): string =>
  text.normalize("NFKC").toLowerCase().replace(/\s+/g, " ").trim();

export function createThreadSearchIndex(
  threads: readonly SearchableThread[],
): ReadonlyMap<string, string> {
  return new Map(threads.map((thread) => {
    const preview = typeof thread.custom?.preview === "string" ? thread.custom.preview : "";
    return [thread.id, normalizeThreadSearch(`${thread.title ?? "New Chat"}\n${preview}`)];
  }));
}

export function matchThreadSearch(
  index: ReadonlyMap<string, string>,
  query: string,
): ReadonlySet<string> | undefined {
  const normalized = normalizeThreadSearch(query);
  if (!normalized) return undefined;
  const matches = new Set<string>();
  for (const [id, text] of index) {
    if (text.includes(normalized)) matches.add(id);
  }
  return matches;
}
