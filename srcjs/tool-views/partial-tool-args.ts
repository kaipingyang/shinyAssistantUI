type PartialJsonString = {
  value: string;
  complete: boolean;
  end: number;
};

const skipWhitespace = (source: string, start: number) => {
  let index = start;
  while (index < source.length && /\s/.test(source[index])) index += 1;
  return index;
};

const incomplete = (value: string, source: string): PartialJsonString => ({
  value,
  complete: false,
  end: source.length,
});

function readJsonString(source: string, start: number): PartialJsonString | undefined {
  if (source[start] !== '"') return undefined;

  let value = "";
  let index = start + 1;

  while (index < source.length) {
    const char = source[index];
    if (char === '"') return { value, complete: true, end: index + 1 };
    if (char !== "\\") {
      // Unescaped control characters are invalid JSON. Keep only the safe prefix.
      if (char.charCodeAt(0) < 0x20) return incomplete(value, source);
      value += char;
      index += 1;
      continue;
    }

    if (index + 1 >= source.length) return incomplete(value, source);
    const escaped = source[index + 1];
    const simpleEscapes: Record<string, string> = {
      '"': '"',
      "\\": "\\",
      "/": "/",
      b: "\b",
      f: "\f",
      n: "\n",
      r: "\r",
      t: "\t",
    };
    if (escaped in simpleEscapes) {
      value += simpleEscapes[escaped];
      index += 2;
      continue;
    }
    if (escaped !== "u") return incomplete(value, source);

    const digits = source.slice(index + 2, index + 6);
    if (digits.length < 4 || !/^[0-9a-fA-F]{4}$/.test(digits)) {
      return incomplete(value, source);
    }
    const unit = Number.parseInt(digits, 16);
    const afterUnit = index + 6;

    // Avoid rendering a transient replacement glyph when a surrogate pair is
    // split across input_json_delta boundaries. A lone high surrogate is still
    // accepted once a following non-pair character proves it is intentional.
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (afterUnit >= source.length) return incomplete(value, source);
      if (source[afterUnit] === "\\" && source[afterUnit + 1] === "u") {
        const lowDigits = source.slice(afterUnit + 2, afterUnit + 6);
        if (lowDigits.length < 4) return incomplete(value, source);
        if (/^[0-9a-fA-F]{4}$/.test(lowDigits)) {
          const low = Number.parseInt(lowDigits, 16);
          if (low >= 0xdc00 && low <= 0xdfff) {
            value += String.fromCodePoint(
              0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00),
            );
            index = afterUnit + 6;
            continue;
          }
        }
      }
    }

    value += String.fromCharCode(unit);
    index = afterUnit;
  }

  return incomplete(value, source);
}

function skipJsonValue(source: string, start: number): number {
  let index = start;
  let depth = 0;
  let inString = false;
  let escaped = false;

  while (index < source.length) {
    const char = source[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === '"') inString = false;
      index += 1;
      continue;
    }

    if (char === '"') inString = true;
    else if (char === "{" || char === "[") depth += 1;
    else if (char === "}" || char === "]") {
      if (depth === 0) return index;
      depth -= 1;
    } else if (char === "," && depth === 0) return index + 1;
    index += 1;
  }

  return index;
}

export function extractPartialTopLevelString(
  source: string,
  field: string,
): PartialJsonString | undefined {
  let index = skipWhitespace(source, 0);
  if (source[index] !== "{") return undefined;
  index += 1;

  while (index < source.length) {
    index = skipWhitespace(source, index);
    if (source[index] === ",") {
      index += 1;
      continue;
    }
    if (source[index] === "}") return undefined;

    const key = readJsonString(source, index);
    if (!key?.complete) return undefined;
    index = skipWhitespace(source, key.end);
    if (source[index] !== ":") return undefined;
    index = skipWhitespace(source, index + 1);

    if (source[index] === '"') {
      const value = readJsonString(source, index);
      if (!value) return undefined;
      if (key.value === field) return value;
      if (!value.complete) return undefined;
      index = value.end;
    } else {
      index = skipJsonValue(source, index);
    }
  }

  return undefined;
}

export function projectPartialWriteArgs(source: string): Record<string, string> {
  const projected: Record<string, string> = {};
  const filePath = extractPartialTopLevelString(source, "file_path");
  const content = extractPartialTopLevelString(source, "content");
  if (filePath) projected.file_path = filePath.value;
  if (content) projected.content = content.value;
  return projected;
}
