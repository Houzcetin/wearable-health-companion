import { errorResponse, requireEnv } from "./supabase.ts";
import { assertEquals } from "./test_helpers.ts";

Deno.test("missing environment settings log their name and return only internal_error", async () => {
  const originalGet = Deno.env.get;
  const originalError = console.error;
  const logs: unknown[][] = [];
  Deno.env.get = () => undefined;
  console.error = (...args) => logs.push(args);
  try {
    let response: Response | undefined;
    try {
      requireEnv("SYNTHETIC_PRIVATE_SETTING");
    } catch (error) {
      response = errorResponse(error);
    }
    assertEquals(response?.status, 500);
    assertEquals(await response?.json(), { error: "internal_error" });
    assertEquals(logs, [["missing_SYNTHETIC_PRIVATE_SETTING"]]);
  } finally {
    Deno.env.get = originalGet;
    console.error = originalError;
  }
});
