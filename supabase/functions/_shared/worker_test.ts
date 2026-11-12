// deno-lint-ignore-file require-await
// Queue doubles implement async interfaces without performing I/O.
import { GoogleError } from "./google.ts";
import type { MetricsUpdate } from "./mapping.ts";
import { type QueueStore, type SyncJob, type UserContext } from "./queue.ts";
import { type HealthReader, runWorker } from "./worker.ts";
import { assertEquals } from "./test_helpers.ts";
import steps from "./fixtures/steps.json" with { type: "json" };
import hrv from "./fixtures/daily-heart-rate-variability.json" with { type: "json" };

type MemoryJob = SyncJob & {
  status: string;
  due: boolean;
  error?: string;
  runAfter?: string | null;
};
function job(id: number, dataType = "steps", userId = "user-1", attempts = 0): MemoryJob {
  return {
    id,
    data_type: dataType,
    user_id: userId,
    date: "2026-11-11",
    attempts,
    status: "pending",
    due: true,
  };
}

class MemoryStore implements QueueStore {
  writes: { userId: string; date: string; metrics: MetricsUpdate }[] = [];
  completedUsers: string[] = [];
  revoked: string[] = [];
  contexts: string[] = [];
  claims: number[] = [];
  constructor(public jobs: MemoryJob[]) {}
  async claim(size: number): Promise<SyncJob[]> {
    this.claims.push(size);
    const jobs = this.jobs.filter((job) => job.status === "pending" && job.due).slice(0, size);
    for (const job of jobs) {
      job.status = "running";
      job.attempts++;
    }
    return jobs.map((job) => ({ ...job }));
  }
  async userContext(userId: string): Promise<UserContext> {
    this.contexts.push(userId);
    return {
      timeZone: "Europe/Istanbul",
      refreshToken: "test-refresh",
      healthUserId: "test-id",
      scopes: [],
    };
  }
  async upsert(userId: string, date: string, metrics: MetricsUpdate): Promise<void> {
    this.writes.push({ userId, date, metrics: { ...metrics } });
  }
  async done(jobs: SyncJob[]): Promise<void> {
    for (const job of jobs) this.jobs.find((row) => row.id === job.id)!.status = "done";
  }
  async retry(job: SyncJob, code: string, runAfter: string | null): Promise<void> {
    const row = this.jobs.find((row) => row.id === job.id)!;
    Object.assign(row, {
      status: runAfter ? "pending" : "failed",
      due: false,
      error: code,
      runAfter,
    });
  }
  async release(job: SyncJob): Promise<void> {
    const row = this.jobs.find((row) => row.id === job.id)!;
    if (row.status === "running") {
      Object.assign(row, { status: "pending", attempts: job.attempts - 1 });
    }
  }
  async revoke(userId: string): Promise<void> {
    this.revoked.push(userId);
    for (const row of this.jobs) {
      if (row.user_id === userId && ["pending", "running"].includes(row.status)) {
        row.status = "failed";
        row.error = "invalid_grant";
      }
    }
  }
  async synced(userId: string): Promise<void> {
    if (
      !this.jobs.some((row) =>
        row.user_id === userId && ["pending", "running"].includes(row.status)
      )
    ) {
      this.completedUsers.push(userId);
    }
  }
  async remaining(): Promise<number> {
    return this.jobs.filter((row) => ["pending", "running"].includes(row.status)).length;
  }
  async rotateToken(): Promise<void> {}
}

const reader: HealthReader = {
  dailyRollUp: () => Promise.resolve(steps),
  listDataPoints: () => Promise.resolve(hrv),
};

Deno.test("worker merges user/date updates, caches access and fetches, and leaves empty metrics alone", async () => {
  const store = new MemoryStore([
    job(1),
    job(2, "daily-heart-rate-variability"),
    job(3),
    job(4, "sleep", "user-2"),
  ]);
  const access: string[] = [];
  let reads = 0;
  const result = await runWorker({
    store,
    healthForUser: (userId) => {
      access.push(userId);
      return Promise.resolve({
        dailyRollUp: () => {
          reads++;
          return Promise.resolve(steps);
        },
        listDataPoints: (type) => Promise.resolve(type === "sleep" ? {} : hrv),
      });
    },
  });
  assertEquals(result, { processed: 4, failed: 0, remaining: 0 });
  assertEquals(access, ["user-1", "user-2"]);
  assertEquals(reads, 1);
  assertEquals(store.writes, [{
    userId: "user-1",
    date: "2026-11-11",
    metrics: { steps: 8432, hrv_ms: 47.3 },
  }]);
  assertEquals(store.completedUsers, ["user-1", "user-2"]);
});

Deno.test("worker retries transient failures exponentially and stops at the fifth attempt", async () => {
  const store = new MemoryStore([job(1, "steps", "user-1", 1), job(2, "steps", "user-2", 4)]);
  const result = await runWorker({
    store,
    clock: () => 0,
    healthForUser: () =>
      Promise.resolve({
        ...reader,
        dailyRollUp: () => Promise.reject(new GoogleError("google_http_503", true)),
      }),
  });
  assertEquals(result, { processed: 2, failed: 2, remaining: 1 });
  assertEquals(store.jobs.map((row) => [row.status, row.runAfter, row.error]), [
    ["pending", "1970-01-01T00:01:00.000Z", "google_http_503"],
    ["failed", null, "google_http_503"],
  ]);
  assertEquals(store.completedUsers, []);
});

Deno.test("invalid_grant revokes only that user and fails their entire queued backlog", async () => {
  const store = new MemoryStore([
    job(1),
    job(2, "sleep"),
    job(3, "steps", "user-2"),
    ...Array.from({ length: 30 }, (_, i) => job(i + 4)),
  ]);
  const access: string[] = [];
  const result = await runWorker({
    store,
    healthForUser: (userId) => {
      access.push(userId);
      return userId === "user-1"
        ? Promise.reject(new GoogleError("invalid_grant", false))
        : Promise.resolve(reader);
    },
  });
  assertEquals(store.revoked, ["user-1"]);
  assertEquals(access, ["user-1", "user-2"]);
  assertEquals(
    store.jobs.filter((row) => row.user_id === "user-1").every((row) => row.status === "failed"),
    true,
  );
  assertEquals(result.remaining, 0);
  assertEquals(store.completedUsers, ["user-2"]);
});

Deno.test("worker releases unstarted claimed jobs on deadline without consuming an attempt", async () => {
  const store = new MemoryStore([job(1), job(2), job(3)]);
  let now = 0;
  const result = await runWorker({
    store,
    clock: () => now,
    timeBudgetMs: 100,
    healthForUser: () =>
      Promise.resolve({
        ...reader,
        dailyRollUp: () => {
          now = 101;
          return Promise.resolve(steps);
        },
      }),
  });
  assertEquals(result, { processed: 1, failed: 0, remaining: 2 });
  assertEquals(store.jobs.map((row) => [row.status, row.attempts]), [["done", 1], ["pending", 0], [
    "pending",
    0,
  ]]);
  assertEquals(store.completedUsers, []);
});

Deno.test("worker caps claims and processed work at 200 and fails unsupported types permanently", async () => {
  const store = new MemoryStore(Array.from({ length: 205 }, (_, i) => job(i + 1)));
  const result = await runWorker({ store, healthForUser: () => Promise.resolve(reader) });
  assertEquals(result, { processed: 200, failed: 0, remaining: 5 });
  assertEquals(store.claims, Array(8).fill(25));
  const badStore = new MemoryStore([job(1, "unknown-type")]);
  assertEquals(await runWorker({ store: badStore, healthForUser: () => Promise.resolve(reader) }), {
    processed: 1,
    failed: 1,
    remaining: 0,
  });
  assertEquals(badStore.jobs[0].error, "unsupported_data_type");
});

Deno.test("worker retries successful fetches when the aggregate write fails", async () => {
  const store = new MemoryStore([job(1), job(2, "daily-heart-rate-variability")]);
  store.upsert = () => Promise.reject(new Error("do not persist raw database text"));
  const result = await runWorker({ store, healthForUser: () => Promise.resolve(reader) });
  assertEquals(result, { processed: 2, failed: 2, remaining: 2 });
  assertEquals(
    store.jobs.every((row) => row.status === "pending" && row.error === "sync_error"),
    true,
  );
});
