import { addDays } from "./dates.ts";
import { type DateRange, GoogleError } from "./google.ts";
import { isDataType, mapDailyMetrics, type MetricsUpdate, READ_METHOD } from "./mapping.ts";
import { QueueError, type QueueStore, type SyncJob, type UserContext } from "./queue.ts";

export interface HealthReader {
  dailyRollUp(dataType: keyof typeof READ_METHOD, date: string): Promise<unknown>;
  listDataPoints(dataType: keyof typeof READ_METHOD, range: DateRange): Promise<unknown>;
}

export interface WorkerDependencies {
  store: QueueStore;
  healthForUser: (
    userId: string,
    context: UserContext,
    signal: AbortSignal,
  ) => Promise<HealthReader>;
  clock?: () => number;
  maxJobs?: number;
  timeBudgetMs?: number;
}

export interface WorkerResult {
  processed: number;
  failed: number;
  remaining: number;
}

export function failure(error: unknown): { code: string; transient: boolean } {
  if (error instanceof GoogleError || error instanceof QueueError) {
    return { code: error.code, transient: error.transient };
  }
  return { code: "sync_error", transient: true };
}

export async function runWorker(deps: WorkerDependencies): Promise<WorkerResult> {
  const { store } = deps;
  const clock = deps.clock ?? Date.now;
  const deadline = clock() + (deps.timeBudgetMs ?? 38000);
  const limit = Math.min(200, deps.maxJobs ?? 200);
  const users = new Map<string, Promise<{ context: UserContext; reader: HealthReader }>>();
  const fetched = new Map<string, Promise<MetricsUpdate>>();
  const outstanding = new Map<SyncJob["id"], SyncJob>();
  const succeeded = new Set<string>();
  const failedUsers = new Set<string>();
  const revoked = new Set<string>();
  let processed = 0;
  let failed = 0;
  let releaseFailed = false;

  async function load(job: SyncJob): Promise<MetricsUpdate> {
    if (!isDataType(job.data_type)) throw new QueueError("unsupported_data_type", false);
    const dataType = job.data_type;
    let user = users.get(job.user_id);
    if (!user) {
      user = (async () => {
        const context = await store.userContext(job.user_id);
        const reader = await deps.healthForUser(
          job.user_id,
          context,
          AbortSignal.timeout(Math.max(1, deadline - clock())),
        );
        return { context, reader };
      })();
      users.set(job.user_id, user);
    }
    const { context, reader } = await user;
    const key = `${job.user_id}/${job.date}/${dataType}`;
    let value = fetched.get(key);
    if (!value) {
      value = (async () => {
        const response = READ_METHOD[dataType] === "rollup"
          ? await reader.dailyRollUp(dataType, job.date)
          : await reader.listDataPoints(dataType, {
            startDate: job.date,
            endDate: addDays(job.date, 1),
            timeZone: context.timeZone,
          });
        return mapDailyMetrics(dataType, response, job.date, context.timeZone);
      })();
      fetched.set(key, value);
    }
    return await value;
  }

  async function reject(job: SyncJob, error: unknown): Promise<void> {
    const problem = failure(error);
    failedUsers.add(job.user_id);
    if (problem.code === "invalid_grant") {
      await store.revoke(job.user_id);
      revoked.add(job.user_id);
    } else {
      const runAfter = problem.transient && job.attempts < 5
        ? new Date(clock() + 30000 * 2 ** Math.max(0, job.attempts - 1)).toISOString()
        : null;
      await store.retry(job, problem.code, runAfter);
    }
    outstanding.delete(job.id);
    failed++;
  }

  try {
    while (processed < limit && clock() < deadline) {
      const jobs = await store.claim(Math.min(25, limit - processed));
      if (!jobs.length) break;
      for (const job of jobs) outstanding.set(job.id, job);
      const groups = new Map<string, SyncJob[]>();
      for (const job of jobs) {
        const key = `${job.user_id}/${job.date}`;
        groups.set(key, [...(groups.get(key) ?? []), job]);
      }
      for (const group of groups.values()) {
        const ready: SyncJob[] = [];
        const metrics: MetricsUpdate = {};
        for (const job of group) {
          if (clock() >= deadline) break;
          processed++;
          if (revoked.has(job.user_id)) {
            outstanding.delete(job.id);
            failed++;
            continue;
          }
          try {
            Object.assign(metrics, await load(job));
            ready.push(job);
          } catch (error) {
            await reject(job, error);
          }
        }
        if (ready.length) {
          if (revoked.has(ready[0].user_id)) {
            for (const job of ready) {
              outstanding.delete(job.id);
              failed++;
            }
          } else {
            try {
              if (Object.keys(metrics).length) {
                await store.upsert(ready[0].user_id, ready[0].date, metrics);
              }
            } catch (error) {
              for (const job of ready) await reject(job, error);
              continue;
            }
            await store.done(ready);
            for (const job of ready) outstanding.delete(job.id);
            succeeded.add(ready[0].user_id);
          }
        }
        if (clock() >= deadline) break;
      }
      if (clock() >= deadline) break;
    }
  } finally {
    // A claimed batch can outlive the deadline. Never strand unstarted jobs in running.
    const releases = await Promise.allSettled(
      [...outstanding.values()].map((job) =>
        revoked.has(job.user_id) ? Promise.resolve() : store.release(job)
      ),
    );
    releaseFailed = releases.some((result) => result.status === "rejected");
  }
  if (releaseFailed) throw new QueueError("queue_release_failed");
  for (const userId of succeeded) if (!failedUsers.has(userId)) await store.synced(userId);
  return { processed, failed, remaining: await store.remaining() };
}
