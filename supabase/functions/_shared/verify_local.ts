// Fallback for Windows sandboxes that deny the standard test runner's named pipe.
// Runs the same cases sequentially, without the standard runner's resource/operation sanitizers.
const cases: { name: string; run: () => unknown | Promise<unknown> }[] = [];
const originalTest = Deno.test;
Object.defineProperty(Deno, "test", {
  configurable: true,
  writable: true,
  value(name: string, run: () => unknown | Promise<unknown>) {
    cases.push({ name, run });
  },
});

try {
  await import("./google_test.ts");
  await import("./mapping_test.ts");
  await import("./state_test.ts");
  await import("./worker_test.ts");
  await import("./queue_test.ts");
  await import("./routes_test.ts");
  await import("./webhook_signature_test.ts");
  await import("./coach_tools_test.ts");
  await import("../sync-worker/handler_test.ts");
  await import("../health-webhook/handler_test.ts");
  await import("../coach/coach_test.ts");
  await import("../export-data/handler_test.ts");
  await import("../delete-account/handler_test.ts");
} finally {
  Object.defineProperty(Deno, "test", { value: originalTest });
}

let failed = 0;
for (const test of cases) {
  try {
    await test.run();
    console.log(`ok | ${test.name}`);
  } catch (error) {
    failed++;
    console.error(`FAILED | ${test.name}`);
    console.error(error);
  }
}
console.log(`${cases.length - failed} passed | ${failed} failed`);
if (failed) Deno.exit(1);
