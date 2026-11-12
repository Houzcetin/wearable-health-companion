export function assert(condition: unknown, message = "Assertion failed"): asserts condition {
  if (!condition) throw new Error(message);
}

function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value !== null && typeof value === "object") {
    return `{${
      Object.entries(value).sort(([a], [b]) => a.localeCompare(b))
        .map(([key, item]) => `${JSON.stringify(key)}:${canonical(item)}`).join(",")
    }}`;
  }
  return JSON.stringify(value);
}

export function assertEquals(actual: unknown, expected: unknown): void {
  if (canonical(actual) !== canonical(expected)) {
    throw new Error(`Expected ${canonical(expected)}; got ${canonical(actual)}`);
  }
}

export async function assertRejects(run: () => Promise<unknown>, code?: string): Promise<void> {
  try {
    await run();
  } catch (error) {
    if (code) assert(error instanceof Error && error.message === code);
    return;
  }
  throw new Error("Expected rejection");
}
