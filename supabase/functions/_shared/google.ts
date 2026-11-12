import { addDays, dateParts, dayBounds } from "./dates.ts";
import type { DataType } from "./mapping.ts";

export const GOOGLE_SCOPES = [
  "sleep",
  "activity_and_fitness",
  "health_metrics_and_measurements",
  "profile",
].map((scope) => `https://www.googleapis.com/auth/googlehealth.${scope}.readonly`);

export class GoogleError extends Error {
  constructor(public code: string, public transient: boolean) {
    super(code);
  }
}

export function record(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

export interface OAuthConfig {
  clientId: string;
  clientSecret: string;
  redirectUri: string;
}

export interface TokenResult {
  accessToken: string;
  refreshToken?: string;
  expiresIn: number;
  scopes: string[];
}

function requestSignal(signal?: AbortSignal): AbortSignal {
  const timeout = AbortSignal.timeout(8000);
  return signal ? AbortSignal.any([signal, timeout]) : timeout;
}

async function requestJson(
  url: string | URL,
  init: RequestInit,
  fetcher: typeof fetch,
  signal?: AbortSignal,
): Promise<Record<string, unknown>> {
  try {
    const response = await fetcher(url, { ...init, signal: requestSignal(signal) });
    const body = record(await response.json());
    if (!response.ok) {
      // Keep provider bodies, which can contain credentials, out of errors and logs.
      if (body.error === "invalid_grant") throw new GoogleError("invalid_grant", false);
      throw new GoogleError(
        `google_http_${response.status}`,
        [408, 425, 429].includes(response.status) || response.status >= 500,
      );
    }
    if (!Object.keys(body).length && response.status !== 200) {
      throw new GoogleError("google_response", true);
    }
    return body;
  } catch (error) {
    if (error instanceof GoogleError) throw error;
    throw new GoogleError("google_transport_or_json", true);
  }
}

async function tokenRequest(
  params: URLSearchParams,
  fetcher: typeof fetch,
  signal?: AbortSignal,
): Promise<TokenResult> {
  const body = await requestJson(
    "https://oauth2.googleapis.com/token",
    {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: params,
    },
    fetcher,
    signal,
  );
  if (
    typeof body.access_token !== "string" || !body.access_token ||
    typeof body.expires_in !== "number" || body.expires_in <= 0
  ) {
    throw new GoogleError("google_token_response", true);
  }
  return {
    accessToken: body.access_token,
    refreshToken: typeof body.refresh_token === "string" ? body.refresh_token : undefined,
    expiresIn: body.expires_in,
    scopes: typeof body.scope === "string" ? body.scope.split(/\s+/).filter(Boolean) : [],
  };
}

export function exchangeCode(
  code: string,
  config: OAuthConfig,
  fetcher: typeof fetch = fetch,
  signal?: AbortSignal,
): Promise<TokenResult> {
  return tokenRequest(
    new URLSearchParams({
      grant_type: "authorization_code",
      code,
      client_id: config.clientId,
      client_secret: config.clientSecret,
      redirect_uri: config.redirectUri,
    }),
    fetcher,
    signal,
  );
}

export function refreshAccessToken(
  refreshToken: string,
  config: Pick<OAuthConfig, "clientId" | "clientSecret">,
  fetcher: typeof fetch = fetch,
  signal?: AbortSignal,
): Promise<TokenResult> {
  return tokenRequest(
    new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: config.clientId,
      client_secret: config.clientSecret,
    }),
    fetcher,
    signal,
  );
}

export interface DateRange {
  startDate: string;
  endDate: string;
  timeZone: string;
}

export class GoogleHealthClient {
  constructor(
    private accessToken: string,
    private fetcher: typeof fetch = fetch,
    private signal?: AbortSignal,
  ) {}

  private request(path: string, init: RequestInit = {}): Promise<Record<string, unknown>> {
    return requestJson(
      `https://health.googleapis.com/v4/${path}`,
      {
        ...init,
        headers: {
          Authorization: `Bearer ${this.accessToken}`,
          "Content-Type": "application/json",
        },
      },
      this.fetcher,
      this.signal,
    );
  }

  async getIdentity(): Promise<string> {
    // UNVERIFIED: confirm users/me/identity returns healthUserId for a connected real account.
    const body = await this.request("users/me/identity");
    if (typeof body.healthUserId !== "string" || !/^[A-Za-z0-9-]{1,63}$/.test(body.healthUserId)) {
      throw new GoogleError("google_identity_response", false);
    }
    return body.healthUserId;
  }

  async dailyRollUp(dataType: DataType, date: string): Promise<Record<string, unknown>> {
    if (!["steps", "active-zone-minutes", "total-calories"].includes(dataType)) {
      throw new GoogleError("unsupported_rollup", false);
    }
    // UNVERIFIED: validate the nested CivilDateTime range and one-day buckets on-device,
    // including agreement between Google's recorded civil dates and the profile timezone.
    const body = {
      range: { start: { date: dateParts(date) }, end: { date: dateParts(addDays(date, 1)) } },
      windowSizeDays: 1,
    };
    return await this.pages(
      `users/me/dataTypes/${dataType}/dataPoints:dailyRollUp`,
      "rollupDataPoints",
      body,
    );
  }

  async listDataPoints(dataType: DataType, range: DateRange): Promise<Record<string, unknown>> {
    dateParts(range.startDate);
    dateParts(range.endDate);
    if (range.startDate >= range.endDate) throw new GoogleError("invalid_range", false);
    let field: string;
    let start = range.startDate;
    let end = range.endDate;
    if (dataType === "sleep") {
      field = "sleep.interval.end_time";
      start = new Date(dayBounds(start, range.timeZone).start).toISOString();
      end = new Date(dayBounds(end, range.timeZone).start).toISOString();
    } else if (dataType === "activity-level") {
      field = "activity_level.interval.start_time";
      // UNVERIFIED: confirm activity intervals never exceed this one-day overlap lookback.
      start = new Date(dayBounds(addDays(start, -1), range.timeZone).start).toISOString();
      end = new Date(dayBounds(end, range.timeZone).start).toISOString();
    } else if (dataType === "exercise") {
      field = "exercise.interval.civil_start_time";
      // Allow recorded device offsets to differ from the current profile timezone.
      start = addDays(start, -2);
      end = addDays(end, 2);
    } else if (dataType.startsWith("daily-")) {
      field = `${dataType.replaceAll("-", "_")}.date`;
    } else {
      throw new GoogleError("unsupported_list", false);
    }
    // UNVERIFIED: confirm snake_case filters (discovery uses them; the HTML daily example uses camelCase),
    // physical sleep-end filters, exercise civil filters and page tokens against a real account.
    const query = new URLSearchParams({
      filter: `${field} >= "${start}" AND ${field} < "${end}"`,
      pageSize: dataType === "sleep" || dataType === "exercise" ? "25" : "10000",
    });
    return await this.pages(`users/me/dataTypes/${dataType}/dataPoints?${query}`, "dataPoints");
  }

  private async pages(
    path: string,
    field: string,
    body?: Record<string, unknown>,
  ): Promise<Record<string, unknown>> {
    const points: unknown[] = [];
    const seen = new Set<string>();
    let pageToken = "";
    for (let page = 0; page < 100; page++) {
      const suffix = pageToken ? `&pageToken=${encodeURIComponent(pageToken)}` : "";
      const result = await this.request(
        body ? path : `${path}${suffix}`,
        body
          ? {
            method: "POST",
            body: JSON.stringify({ ...body, ...(pageToken ? { pageToken } : {}) }),
          }
          : {},
      );
      if (result[field] !== undefined && !Array.isArray(result[field])) {
        throw new GoogleError("google_points_response", true);
      }
      points.push(...(result[field] as unknown[] | undefined ?? []));
      if (!result.nextPageToken) return { [field]: points };
      if (typeof result.nextPageToken !== "string" || seen.has(result.nextPageToken)) {
        throw new GoogleError("google_pagination", true);
      }
      pageToken = result.nextPageToken;
      seen.add(pageToken);
    }
    throw new GoogleError("google_page_limit", true);
  }
}
