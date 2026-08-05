import { describe, expect, it, vi } from "vitest";
import {
  HttpLocalDataProvider,
  isPathInsideQaRoot,
  qaPathsAreIsolated,
} from "./local";

describe("HttpLocalDataProvider", () => {
  it("surfaces an authenticated API failure without exposing the token", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(
        JSON.stringify({
          error: {
            code: "unauthorised",
            message: "The local-core access token is missing or invalid.",
            request_id: "request-1",
          },
        }),
        { status: 401, headers: { "Content-Type": "application/json" } },
      ),
    );
    const provider = new HttpLocalDataProvider({
      status: "ready",
      address: "http://127.0.0.1:49152",
      token: "fixture-secret",
    });
    await expect(provider.getProjects()).rejects.toMatchObject({
      code: "unauthorised",
      requestId: "request-1",
    });
  });

  it("accepts only frontend-visible paths inside the canonical QA root", () => {
    const root = "C:\\runner\\DevPulse-QA-installed";
    const pathStatus = {
      schemaVersion: 2,
      qaMode: true as const,
      installQa: true,
      qaRoot: root,
      tauriAppConfigurationDirectory: `${root}\\tauri\\config`,
      tauriAppDataDirectory: `${root}\\tauri\\data`,
      tauriLocalDataDirectory: `${root}\\tauri\\local-data`,
      tauriCacheDirectory: `${root}\\tauri\\cache`,
      tauriLogDirectory: `${root}\\tauri\\logs`,
      webView2UserDataDirectory: `${root}\\webview2`,
      pythonLocalCoreConfigurationDirectory: root,
      pythonCacheDirectory: `${root}\\cache`,
      pythonLogDirectory: `${root}\\logs`,
      qaRepositoryDirectory: `${root}\\test-lab`,
      diagnosticsExportDirectory: `${root}\\diagnostics`,
      activityStorage: `${root}\\activity\\events-v1.json`,
      environmentMatchesCanonicalPlan: true,
      tauriWebViewDirectoryMatchesCanonicalPlan: true,
      allWritablePathsUnderQaRoot: true,
    };
    expect(qaPathsAreIsolated(pathStatus)).toBe(true);
    expect(
      qaPathsAreIsolated({
        ...pathStatus,
        tauriLocalDataDirectory:
          "C:\\Users\\fixture\\AppData\\Local\\com.devpulse.desktop",
      }),
    ).toBe(false);
    expect(isPathInsideQaRoot(`${root}2\\escape`, root)).toBe(false);
    expect(isPathInsideQaRoot(`${root}\\folder\\..\\escape`, root)).toBe(false);
  });
});
