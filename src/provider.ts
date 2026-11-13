import { spawn } from "node:child_process";
import type { ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { setTimeout as delay } from "node:timers/promises";
import { join } from "node:path";
import type { Capabilities, Clock, Controller } from "./contracts.ts";
import { PiClient } from "./pi-client.ts";
import { structuredResult, toolExecution } from "./tool-contract.ts";
import { createPadPlayer } from "./pad.ts";
import { compileTimeline } from "./timeline.ts";
import { AXES, BUTTONS, decodeButtons, decodeStickPayload } from "./calibration.ts";
import { MAX_CAPTURE_DELAY_MS, MIN_POLL_DURATION_MS, padTools, POLLED_TIMING } from "./schema.ts";

const ROOT = import.meta.dir.replace(/\/src$/, "");
const CAPTURE_BINARY = join(ROOT, "native/build/switch2-capture");
const CAPTURE_BUILD = join(ROOT, "scripts/build-capture.sh");
const DEFAULT_CAPTURE_MAX_RETRIES = 2;
const DEFAULT_CAPTURE_RETRY_DELAY_MS = 250;
const CAPTURE_REQUEST_TIMEOUT_MS = 5_000;
const CAPTURE_STATUS_TIMEOUT_MS = 1_500;

export interface Switch2ProviderOptions {
  port?: number;
  clock: Clock;
  piUrl?: string;
  captureUrl?: string;
  /** Tests inject a prebuilt client and skip SSH/capture startup. */
  client?: PiClient;
  keepaliveIntervalMs?: number;
  spawnCapture?: boolean;
  /** Optional binary override for capture daemon launch tests. */
  captureBinary?: string;
  /** Max transient retries for screen.capture on network errors or HTTP 502/503/504 (default: 2). */
  captureMaxRetries?: number;
  /** Delay in ms between transient screen.capture retries (default: 250). */
  captureRetryDelayMs?: number;
}

interface CaptureStatus {
  ok: boolean;
  device?: string;
  mode?: string;
  headless?: boolean;
  width?: number;
  height?: number;
  fps?: number;
  frameSequence?: number;
  capturedAtMs?: number;
}

async function ensureCaptureService(captureUrl: string, captureBinary = CAPTURE_BINARY): Promise<ChildProcess | undefined> {
  let existingDaemonDetected = false;
  try {
    const response = await fetch(`${captureUrl}/status`, {
      signal: AbortSignal.timeout(CAPTURE_STATUS_TIMEOUT_MS),
      proxy: "",
    } as RequestInit);
    if (response.ok) {
      const status = await response.json() as CaptureStatus;
      if (status.ok) return undefined;
      if (typeof status.ok === "boolean") existingDaemonDetected = true;
    }
  } catch { /* not running */ }
  if (existingDaemonDetected) {
    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline) {
      await delay(200);
      try {
        const response = await fetch(`${captureUrl}/status`, {
          signal: AbortSignal.timeout(CAPTURE_STATUS_TIMEOUT_MS),
          proxy: "",
        } as RequestInit);
        if (response.ok) {
          const status = await response.json() as CaptureStatus;
          if (status.ok && (status.frameSequence ?? 0) > 0) return undefined;
        }
      } catch { break; }
    }
    if (existingDaemonDetected) {
      try {
        const response = await fetch(`${captureUrl}/status`, {
          signal: AbortSignal.timeout(CAPTURE_STATUS_TIMEOUT_MS),
          proxy: "",
        } as RequestInit);
        if (response.ok) {
          const status = await response.json() as CaptureStatus;
          if (status.ok) return undefined;
          throw new Error(`Existing Switch 2 capture service at ${captureUrl} is running but capture card is not ready`);
        }
      } catch (error) {
        if (error instanceof Error && error.message.startsWith("Existing Switch 2 capture service")) throw error;
        /* daemon exited while polling; fall through to spawn a fresh headless daemon */
      }
    }
  }
  if (!existsSync(captureBinary)) {
    if (captureBinary !== CAPTURE_BINARY) {
      throw new Error(`Switch 2 capture binary not found: ${captureBinary}`);
    }
    const build = spawn("bash", [CAPTURE_BUILD], { stdio: "inherit" });
    await new Promise<void>((resolve, reject) => {
      build.on("exit", code => code === 0 ? resolve() : reject(new Error(`capture build failed (${code})`)));
      build.on("error", reject);
    });
  }
  const parsedPort = (() => { try { return new URL(captureUrl).port; } catch { return ""; } })();
  const env = parsedPort ? { ...process.env, LUDENS_SWITCH2_CAPTURE_PORT: parsedPort } : process.env;
  const child = spawn(captureBinary, ["--headless"], { stdio: "ignore", detached: false, env });
  let exited: string | undefined;
  let spawnError: Error | undefined;
  child.once("exit", (code, signal) => { exited = signal ? `signal ${signal}` : `code ${code ?? "unknown"}`; });
  child.once("error", err => { spawnError = err; });
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    if (spawnError) throw spawnError;
    if (exited !== undefined) {
      throw new Error(`Switch 2 capture service exited before becoming ready (${exited})`);
    }
    await delay(200);
    if (spawnError) throw spawnError;
    if (exited !== undefined) {
      throw new Error(`Switch 2 capture service exited before becoming ready (${exited})`);
    }
    try {
      const response = await fetch(`${captureUrl}/status`, {
        signal: AbortSignal.timeout(CAPTURE_STATUS_TIMEOUT_MS),
        proxy: "",
      } as RequestInit);
      if (response.ok) {
        const status = await response.json() as CaptureStatus;
        if (status.ok && (status.frameSequence ?? 0) > 0) return child;
      }
    } catch { /* warming up */ }
  }
  child.kill("SIGTERM");
  throw new Error(`Switch 2 capture service at ${captureUrl} did not produce frames within 10s`);
}

export async function createSwitch2Provider(options: Switch2ProviderOptions) {
  const { clock } = options;
  const port = options.port ?? 18765;
  const client = options.client ?? new PiClient({ port, piUrl: options.piUrl });
  const startedClient = !options.client;
  await client.connect();
  const captureUrl = options.captureUrl
    ?? process.env.LUDENS_SWITCH2_CAPTURE_URL
    ?? `http://127.0.0.1:${process.env.LUDENS_SWITCH2_CAPTURE_PORT ?? 18766}`;
  const shouldSpawnCapture = options.spawnCapture ?? (!options.captureUrl && process.env.LUDENS_SWITCH2_CAPTURE_URL === undefined);
  let captureProcess: ChildProcess | undefined;
  if (shouldSpawnCapture) {
    try { captureProcess = await ensureCaptureService(captureUrl, options.captureBinary); }
    catch (error) {
      if (startedClient) client.close();
      throw error;
    }
  }

  let owner: string | undefined;
  const player = createPadPlayer({ client, clock, keepaliveIntervalMs: options.keepaliveIntervalMs, owns: epoch => owner === epoch });
  const owns = (epoch: string) => owner === epoch;
  async function acquire(epoch: string) {
    if (owner === epoch) return;
    player.reset();
    owner = epoch;
  }
  async function release(epoch: string) {
    if (owner !== epoch) return;
    owner = undefined;
    await player.releaseAll({ controlSignal: undefined, record: undefined }).catch(() => {});
    await player.settle();
  }

  const captureMaxRetries = options.captureMaxRetries ?? DEFAULT_CAPTURE_MAX_RETRIES;
  const captureRetryDelayMs = options.captureRetryDelayMs ?? DEFAULT_CAPTURE_RETRY_DELAY_MS;

  const screen: Controller = {
    tool: {
      name: "screen.capture",
      description: "Capture the latest frame from the Switch 2 HDMI capture card as JPEG (default) or PNG after an optional fixed delay. sourceSequence is the capture helper's frame counter.",
      inputSchema: {
        type: "object",
        properties: {
          delayMs: { type: "integer", minimum: 0, maximum: MAX_CAPTURE_DELAY_MS, default: 0 },
          format: { type: "string", enum: ["jpeg", "png"], default: "jpeg" },
        },
        additionalProperties: false,
      },
      annotations: { readOnlyHint: true },
    },
    requiresControl: false,
    mediaTypes: ["image/jpeg", "image/png"],
    async execute(args, { signal }) {
      const delayMs = args.delayMs ?? 0;
      const format = args.format ?? "jpeg";
      if (typeof delayMs !== "number" || !Number.isInteger(delayMs) || delayMs < 0 || delayMs > MAX_CAPTURE_DELAY_MS) {
        throw new Error("delayMs must be an integer from 0 to 2147483647");
      }
      if (format !== "jpeg" && format !== "png") throw new Error("format must be 'jpeg' or 'png'");
      signal.throwIfAborted();
      const id = crypto.randomUUID();
      const requestedAtMs = clock.now();
      if (delayMs > 0) await delay(delayMs, undefined, { signal });
      signal.throwIfAborted();

      let response: Response | undefined;
      let bodyBytes: ArrayBuffer | undefined;
      let lastError: unknown;
      for (let attempt = 0; attempt <= captureMaxRetries; attempt++) {
        signal.throwIfAborted();
        const attemptSignal = AbortSignal.any([signal, AbortSignal.timeout(CAPTURE_REQUEST_TIMEOUT_MS)]);
        try {
          const candidate = await fetch(`${captureUrl}/capture?format=${format}`, { signal: attemptSignal, proxy: "" } as RequestInit);
          if (candidate.status === 502 || candidate.status === 503 || candidate.status === 504) {
            await candidate.body?.cancel().catch(() => {});
            lastError = new Error(`Capture service returned HTTP ${candidate.status}`);
            if (attempt < captureMaxRetries) {
              await delay(captureRetryDelayMs, undefined, { signal });
              continue;
            }
            throw lastError;
          }
          if (!candidate.ok) {
            await candidate.body?.cancel().catch(() => {});
            throw new Error(`Capture service returned HTTP ${candidate.status}`);
          }
          bodyBytes = await candidate.arrayBuffer();
          response = candidate;
          break;
        } catch (error) {
          signal.throwIfAborted();
          lastError = error;
          if (error instanceof Error && /^Capture service returned HTTP (?!50[234]\b)/.test(error.message)) {
            throw error;
          }
          if (attempt < captureMaxRetries) {
            await delay(captureRetryDelayMs, undefined, { signal });
            continue;
          }
          throw error;
        }
      }
      if (!response || !bodyBytes) throw lastError ?? new Error("Capture failed");

      const sequence = Number(response.headers.get("X-Frame-Sequence"));
      const width = Number(response.headers.get("X-Frame-Width"));
      const height = Number(response.headers.get("X-Frame-Height"));
      const data = Buffer.from(bodyBytes).toString("base64");
      const mimeType = format === "png" ? "image/png" : "image/jpeg";
      const timing = { clock: clock.id, requestedAtMs, receivedAtMs: clock.now() };
      const output = { source: "screen", sourceSequence: sequence, width, height, format, timing };
      const result = structuredResult(output);
      result.content.unshift({ type: "image", mimeType, data });
      return { ...toolExecution(clock, requestedAtMs, result), timing,
        observations: [{ id, controllerId: "screen.capture", mediaType: mimeType, timing, sourceSequence: sequence, contentIndex: 0 }] };
    },
  };

  const pads: Controller[] = padTools(BUTTONS, AXES, POLLED_TIMING).map(tool => ({
    tool, requiresControl: true, acquire, release,
    async execute(args, context) {
      const { epoch, signal } = context;
      signal.throwIfAborted();
      if (!epoch || !owns(epoch)) throw new Error("STALE_EPOCH");
      const command = tool.name.slice("pad.".length);
      if (command === "play") {
        args = { ...args, spans: compileTimeline(args.inputs, BUTTONS, AXES, MIN_POLL_DURATION_MS) };
        return player.execute(command, args, context);
      }
      if (command !== "state" && command !== "release") return player.execute(command, args, context);
      const requestedAtMs = clock.now();
      let output: Record<string, unknown>;
      if (command === "state") {
        const state = await client.getState();
        const buttons = state.result?.buttons ?? [0, 0, 0];
        const sticks = state.result?.sticks ?? [2159, 1916, 2070, 2013];
        output = { state: { ...decodeButtons(buttons), ...decodeStickPayload(sticks) } };
      } else {
        await player.releaseAll(context);
        output = { released: true };
      }
      return toolExecution(clock, requestedAtMs, structuredResult(output), { readOnly: command === "state" });
    },
  }));

  return {
    capabilities: { controllers: [...pads, screen] } satisfies Capabilities,
    onDisconnect(_handler: (error: Error) => void) { /* HTTP polling bridge has no disconnect event */ },
    close() {
      captureProcess?.kill("SIGTERM");
      client.close();
    },
  };
}
