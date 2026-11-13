import { describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AXES, BUTTONS, decodeAxis, decodeButtons, encodeAxis, encodeButtons, encodeSpanState } from "../src/calibration.ts";
import { compileTimeline } from "../src/timeline.ts";
import { createSwitch2Provider } from "../src/provider.ts";
import { PiClient } from "../src/pi-client.ts";
import type { Clock } from "../src/contracts.ts";

const clock: Clock = { id: "test", now: () => Date.now() };

describe("calibration", () => {
  test("button bitmasks for all 18 buttons", () => {
    expect(encodeButtons(["A"])).toEqual([0x08, 0, 0]);
    expect(encodeButtons(["B"])).toEqual([0x04, 0, 0]);
    expect(encodeButtons(["X"])).toEqual([0x02, 0, 0]);
    expect(encodeButtons(["Y"])).toEqual([0x01, 0, 0]);
    expect(encodeButtons(["R"])).toEqual([0x40, 0, 0]);
    expect(encodeButtons(["ZR"])).toEqual([0x80, 0, 0]);
    expect(encodeButtons(["MINUS"])).toEqual([0, 0x01, 0]);
    expect(encodeButtons(["PLUS"])).toEqual([0, 0x02, 0]);
    expect(encodeButtons(["RSTICK"])).toEqual([0, 0x04, 0]);
    expect(encodeButtons(["LSTICK"])).toEqual([0, 0x08, 0]);
    expect(encodeButtons(["HOME"])).toEqual([0, 0x10, 0]);
    expect(encodeButtons(["CAPTURE"])).toEqual([0, 0x20, 0]);
    expect(encodeButtons(["DOWN"])).toEqual([0, 0, 0x01]);
    expect(encodeButtons(["UP"])).toEqual([0, 0, 0x02]);
    expect(encodeButtons(["RIGHT"])).toEqual([0, 0, 0x04]);
    expect(encodeButtons(["LEFT"])).toEqual([0, 0, 0x08]);
    expect(encodeButtons(["L"])).toEqual([0, 0, 0x40]);
    expect(encodeButtons(["ZL"])).toEqual([0, 0, 0x80]);
    expect(encodeButtons(["A", "PLUS", "LEFT", "HOME", "ZR"])).toEqual([0x88, 0x12, 0x08]);
    expect(Object.keys(decodeButtons([0x88, 0x12, 0x08])).sort()).toEqual([...BUTTONS].sort());
    expect(decodeButtons([0x88, 0x12, 0x08]).A).toBe(1);
    expect(decodeButtons([0x88, 0x12, 0x08]).HOME).toBe(1);
    expect(decodeButtons([0x88, 0x12, 0x08]).B).toBe(0);
  });

  test("stick calibration endpoints and centers round-trip", () => {
    expect([0, 1, 2, 3].map(i => encodeAxis(AXES[i]!, 0))).toEqual([2159, 1916, 2070, 2013]);
    expect(encodeAxis("LX", 1)).toBe(3625);
    expect(encodeAxis("LX", -1)).toBe(642);
    expect(encodeAxis("LY", 1)).toBe(3499);
    expect(encodeAxis("LY", -1)).toBe(451);
    expect(encodeAxis("RX", 1)).toBe(3484);
    expect(encodeAxis("RX", -1)).toBe(548);
    expect(encodeAxis("RY", 1)).toBe(3523);
    expect(encodeAxis("RY", -1)).toBe(482);
    for (const axis of AXES) {
      expect(decodeAxis(axis, encodeAxis(axis, 0))).toBe(0);
      expect(decodeAxis(axis, encodeAxis(axis, 1))).toBe(1);
      expect(decodeAxis(axis, encodeAxis(axis, -1))).toBe(-1);
    }
    expect(encodeAxis("LX", 2)).toBe(4095);
    expect(encodeAxis("LX", -2)).toBe(0);
    expect(encodeSpanState({ A: 1, LX: 1 })).toEqual({ buttons: [0x08, 0, 0], sticks: [3625, 1916, 2070, 2013] });
  });
});

interface RecordedRequest { method: string; path: string; body?: unknown }

function startMockPi(options: { inputDelayMs?: number; initialState?: "connected" | "waiting" } = {}) {
  const requests: RecordedRequest[] = [];
  let buttons = [0, 0, 0];
  let sticks = [2159, 1916, 2070, 2013];
  let connectionState: "connected" | "waiting" = options.initialState ?? "connected";
  const server = Bun.serve({
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      requests.push({ method: request.method, path: url.pathname, body: request.method === "POST" ? await request.json() : undefined });
      if (url.pathname === "/state") {
        return Response.json({
          ok: true, version: 1,
          result: { state: connectionState, initialized: connectionState === "connected", peer: connectionState === "connected" ? "aa:bb" : "", player_lights: connectionState === "connected" ? 1 : 0, buttons, sticks },
        });
      }
      if (url.pathname === "/input") {
        if (options.inputDelayMs) await new Promise(resolve => setTimeout(resolve, options.inputDelayMs));
        const body = requests.at(-1)!.body as { buttons: number[]; sticks: number[] };
        buttons = body.buttons; sticks = body.sticks;
        return Response.json({
          ok: true, version: 1,
          result: { state: connectionState, initialized: connectionState === "connected" },
        });
      }
      if (url.pathname === "/release") {
        buttons = [0, 0, 0]; sticks = [2159, 1916, 2070, 2013];
        return Response.json({ ok: true, version: 1, result: { state: connectionState, initialized: connectionState === "connected" } });
      }
      return new Response("not found", { status: 404 });
    },
  });
  return {
    requests,
    setState: (next: "connected" | "waiting") => { connectionState = next; },
    close: () => server.stop(true),
    url: `http://127.0.0.1:${server.port}`,
  };
}

const jpegBytes = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
const pngBytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
let frameSequence = 0;

function startMockCapture() {
  const server = Bun.serve({
    port: 0,
    fetch(request) {
      const url = new URL(request.url);
      if (url.pathname === "/status") {
        return Response.json({ ok: true, device: "USB Video", width: 1280, height: 720, fps: 60, frameSequence, capturedAtMs: 1234 });
      }
      if (url.pathname === "/capture") {
        frameSequence += 1;
        const png = url.searchParams.get("format") === "png";
        return new Response(png ? pngBytes : jpegBytes, {
          headers: { "Content-Type": png ? "image/png" : "image/jpeg", "X-Frame-Sequence": String(frameSequence), "X-Frame-Width": "1280", "X-Frame-Height": "720" },
        });
      }
      return new Response("not found", { status: 404 });
    },
  });
  return { close: () => server.stop(true), url: `http://127.0.0.1:${server.port}` };
}

interface PadStateOutput { state: Record<string, number> }
interface PlayOutput { status: string; spans: number; inputWrites: number }
interface CaptureOutput { sourceSequence: number; format: string; width: number }
interface InputBody { buttons: number[] }

async function openProvider(piUrl: string, captureUrl: string, keepaliveIntervalMs = 20) {
  const provider = await createSwitch2Provider({
    clock, piUrl, captureUrl, client: new PiClient({ piUrl }), keepaliveIntervalMs,
  });
  const controllers = provider.capabilities.controllers;
  const find = (name: string) => {
    const controller = controllers.find(item => item.tool.name === name);
    if (!controller) throw new Error(`missing controller ${name}`);
    return controller;
  };
  return { provider, find };
}

const context = (epoch?: string) => ({ epoch, signal: new AbortController().signal });

describe("provider with mock Pi and capture servers", () => {
  test("pad.state decodes 18 buttons and calibrated axes", async () => {
    const pi = startMockPi();
    const capture = startMockCapture();
    const { provider, find } = await openProvider(pi.url, capture.url);
    const pad = find("pad.state");
    await pad.acquire?.("epoch-1");
    // Prime the mock bridge with A + HOME pressed, sticks at full excursion.
    await fetch(`${pi.url}/input`, { method: "POST", body: JSON.stringify({ buttons: [0x08, 0x10, 0], sticks: [3625, 451, 548, 3523] }) });
    const result = await pad.execute({}, context("epoch-1"));
    const output = result.result.structuredContent as unknown as PadStateOutput;
    expect(Object.keys(output.state).sort()).toEqual([...BUTTONS, ...AXES].sort());
    expect(output.state.A).toBe(1);
    expect(output.state.HOME).toBe(1);
    expect(output.state.B).toBe(0);
    expect(output.state.LX).toBe(1);
    expect(output.state.LY).toBe(-1);
    expect(output.state.RX).toBe(-1);
    expect(output.state.RY).toBe(1);
    provider.close(); pi.close(); capture.close();
  });

  // Real timers on purpose: pad playback exercises genuine interval/keepalive timing.
  test("pad.play compiles spans, sends /input keepalives, then /release", async () => {
    const pi = startMockPi();
    const capture = startMockCapture();
    const { provider, find } = await openProvider(pi.url, capture.url);
    const play = find("pad.play");
    await play.acquire?.("epoch-1");
    const events: string[] = [];
    const record = (type: string) => events.push(type);
    const result = await play.execute({ inputs: [
      { atMs: 0, durationMs: 80, state: { A: 1 } },
      { atMs: 40, durationMs: 200, state: { LX: 1 } },
    ], wait: true }, { ...context("epoch-1"), record });
    expect(result.status).toBe("completed");
    const output = result.result.structuredContent as unknown as PlayOutput;
    expect(output.status).toBe("completed");
    expect(output.spans).toBe(3);
    const inputs = pi.requests.filter(request => request.path === "/input");
    expect(inputs.length).toBe(output.inputWrites);
    // The 200ms span exceeds one keepalive interval; it must have been re-sent.
    expect(inputs.length).toBeGreaterThan(3);
    expect(pi.requests.some(request => request.path === "/release")).toBe(true);
    const lastInput = inputs.at(-1)!.body as unknown as InputBody;
    expect(lastInput.buttons).toEqual([0, 0, 0]);
    expect(events).toEqual(["action_start", "action_end"]);
    provider.close(); pi.close(); capture.close();
  });

  // Real timers: interruption racing against genuine span playback.
  test("pad.cancel interrupts; an aborted pad.wait does not", async () => {
    const pi = startMockPi();
    const capture = startMockCapture();
    const { provider, find } = await openProvider(pi.url, capture.url);
    const play = find("pad.play");
    const cancel = find("pad.cancel");
    const wait = find("pad.wait");
    await play.acquire?.("epoch-1");
    const events: string[] = [];
    const record = (type: string) => events.push(type);
    const submitted = await play.execute({ inputs: [{ atMs: 0, durationMs: 400, state: { B: 1 } }] },
      { ...context("epoch-1"), record });
    const actionId = submitted.actionId!;
    expect(submitted.status).toBe("completed");
    // Aborting the waiter's own signal must not cancel the running action.
    const waiter = new AbortController();
    const waitPromise = wait.execute({ actionId }, { epoch: "epoch-1", signal: waiter.signal, record });
    waiter.abort();
    await expect(waitPromise).rejects.toThrow();
    await new Promise(resolve => setTimeout(resolve, 60));
    expect(pi.requests.filter(request => request.path === "/release")).toHaveLength(0);
    const cancelled = await cancel.execute({ actionId }, { ...context("epoch-1"), record });
    expect(cancelled.status).toBe("interrupted");
    expect(cancelled.exitCode).toBe(130);
    expect(pi.requests.some(request => request.path === "/release")).toBe(true);
    expect(events).toContain("action_end");
    provider.close(); pi.close(); capture.close();
  });

  test("release(epoch) interrupts a running action", async () => {
    const pi = startMockPi();
    const capture = startMockCapture();
    const { provider, find } = await openProvider(pi.url, capture.url);
    const play = find("pad.play");
    await play.acquire?.("epoch-1");
    await play.execute({ inputs: [{ atMs: 0, durationMs: 400, state: { Y: 1 } }] }, context("epoch-1"));
    await play.release?.("epoch-1");
    await new Promise(resolve => setTimeout(resolve, 50));
    expect(pi.requests.some(request => request.path === "/release")).toBe(true);
    provider.close(); pi.close(); capture.close();
  });

  test("screen.capture returns jpeg/png with sourceSequence", async () => {
    const pi = startMockPi();
    const capture = startMockCapture();
    const { provider, find } = await openProvider(pi.url, capture.url);
    const screen = find("screen.capture");
    const jpeg = await screen.execute({}, context());
    const jpegOutput = jpeg.result.structuredContent as unknown as CaptureOutput;
    expect(jpegOutput.format).toBe("jpeg");
    expect(jpegOutput.sourceSequence).toBeGreaterThan(0);
    expect(jpegOutput.width).toBe(1280);
    expect(jpeg.result.content[0]).toMatchObject({ type: "image", mimeType: "image/jpeg" });
    const png = await screen.execute({ format: "png", delayMs: 10 }, context());
    const pngOutput = png.result.structuredContent as unknown as CaptureOutput;
    expect(pngOutput.format).toBe("png");
    expect(png.result.content[0]).toMatchObject({ type: "image", mimeType: "image/png" });
    expect(png.observations?.[0]?.sourceSequence).toBeGreaterThan(0);
    provider.close(); pi.close(); capture.close();
  });

  test("pad.play anchors span deadlines to wall clock even when /input has network latency", async () => {
    const pi = startMockPi({ inputDelayMs: 25 });
    const capture = startMockCapture();
    const { provider, find } = await openProvider(pi.url, capture.url, 40);
    const play = find("pad.play");
    await play.acquire?.("epoch-1");
    const startedAt = Date.now();
    const result = await play.execute({ inputs: [{ atMs: 0, durationMs: 300, state: { A: 1 } }], wait: true }, context("epoch-1"));
    const elapsedMs = Date.now() - startedAt;
    expect(result.status).toBe("completed");
    // Without deadline anchoring, ~6 keepalive writes * 25ms HTTP RTT would inflate 300ms to ~460ms+.
    expect(elapsedMs).toBeGreaterThanOrEqual(290);
    expect(elapsedMs).toBeLessThan(370);
    provider.close(); pi.close(); capture.close();
  });

  test("PiClient auto-reconnects when Switch drops Bluetooth into waiting state", async () => {
    const pi = startMockPi({ initialState: "waiting" });
    const capture = startMockCapture();
    let reconnectCalls = 0;
    const client = new PiClient({
      piUrl: pi.url,
      onReconnect: async () => {
        reconnectCalls += 1;
        pi.setState("connected");
      },
    });
    const provider = await createSwitch2Provider({ clock, piUrl: pi.url, captureUrl: capture.url, client, keepaliveIntervalMs: 30 });
    expect(reconnectCalls).toBe(1);
    const play = provider.capabilities.controllers.find(item => item.tool.name === "pad.play")!;
    await play.acquire?.("epoch-1");
    // Simulate Switch entering Change Grip/Order mid-session and dropping Bluetooth.
    pi.setState("waiting");
    const result = await play.execute({ inputs: [{ atMs: 0, durationMs: 60, state: { L: 1, R: 1 } }], wait: true }, context("epoch-1"));
    expect(result.status).toBe("completed");
    expect(reconnectCalls).toBe(2);
    provider.close(); pi.close(); capture.close();
  });

  test("ensureCaptureService spawns capture binary with --headless and terminates it on close()", async () => {
    const pi = startMockPi();
    const probe = Bun.serve({ port: 0, fetch: () => new Response("probe") });
    const freePort = probe.port!;
    probe.stop(true);

    const dir = mkdtempSync(join(tmpdir(), "switch2-capture-headless-"));
    const argsFile = join(dir, "args.json");
    const binPath = join(dir, "fake-switch2-capture");
    writeFileSync(binPath, `#!/usr/bin/env bun
import { writeFileSync } from "node:fs";
const port = Number(process.env.LUDENS_SWITCH2_CAPTURE_PORT || "18766");
writeFileSync(${JSON.stringify(argsFile)}, JSON.stringify({ argv: process.argv.slice(2), port }));
const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
const server = Bun.serve({
  port,
  fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/status" || url.pathname === "/health") {
      return Response.json({ ok: true, headless: true, width: 1920, height: 1080, fps: 60, frameSequence: 5 });
    }
    if (url.pathname === "/capture") {
      return new Response(jpeg, {
        headers: { "Content-Type": "image/jpeg", "X-Frame-Sequence": "5", "X-Frame-Width": "1920", "X-Frame-Height": "1080" },
      });
    }
    return new Response("not found", { status: 404 });
  },
});
process.on("SIGTERM", () => { server.stop(true); process.exit(0); });
`, "utf8");
    chmodSync(binPath, 0o755);

    try {
      const captureUrl = `http://127.0.0.1:${freePort}`;
      const provider = await createSwitch2Provider({
        clock,
        piUrl: pi.url,
        captureUrl,
        client: new PiClient({ piUrl: pi.url, sshTunnel: false }),
        spawnCapture: true,
        captureBinary: binPath,
      });
      const recorded = JSON.parse(readFileSync(argsFile, "utf8")) as { argv: string[]; port: number };
      expect(recorded.argv).toEqual(["--headless"]);
      expect(recorded.port).toBe(freePort);

      const screen = provider.capabilities.controllers.find(item => item.tool.name === "screen.capture")!;
      const shot = await screen.execute({}, context());
      const out = shot.result.structuredContent as unknown as CaptureOutput;
      expect(out.sourceSequence).toBe(5);
      expect(out.width).toBe(1920);

      provider.close();
      await new Promise(resolve => setTimeout(resolve, 100));
      await expect(fetch(`${captureUrl}/status`, { proxy: "" } as RequestInit)).rejects.toThrow();
    } finally {
      pi.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("ensureCaptureService fails fast when headless capture binary exits on startup", async () => {
    const pi = startMockPi();
    const probe = Bun.serve({ port: 0, fetch: () => new Response("probe") });
    const freePort = probe.port!;
    probe.stop(true);

    const dir = mkdtempSync(join(tmpdir(), "switch2-capture-failfast-"));
    const binPath = join(dir, "fail-switch2-capture");
    writeFileSync(binPath, "#!/usr/bin/env bash\nexit 2\n", "utf8");
    chmodSync(binPath, 0o755);

    try {
      const startedAt = Date.now();
      await expect(createSwitch2Provider({
        clock,
        piUrl: pi.url,
        captureUrl: `http://127.0.0.1:${freePort}`,
        client: new PiClient({ piUrl: pi.url, sshTunnel: false }),
        spawnCapture: true,
        captureBinary: binPath,
      })).rejects.toThrow(/exited before becoming ready/);
      expect(Date.now() - startedAt).toBeLessThan(2000);
    } finally {
      pi.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("screen.capture retries transient 503 and network errors (250ms backoff), fails fast on 500 or abort", async () => {
    const pi = startMockPi();
    let captureCalls = 0;
    let mode: "transient-503" | "hard-500" = "transient-503";
    const flakyServer = Bun.serve({
      port: 0,
      fetch(req) {
        const url = new URL(req.url);
        if (url.pathname === "/status") {
          return Response.json({ ok: true, width: 1280, height: 720, fps: 60, frameSequence: 10 });
        }
        if (url.pathname === "/capture") {
          captureCalls += 1;
          if (mode === "hard-500") return new Response("encode failed", { status: 500 });
          if (captureCalls <= 2) return new Response("no frame available", { status: 503 });
          return new Response(jpegBytes, {
            headers: { "Content-Type": "image/jpeg", "X-Frame-Sequence": "11", "X-Frame-Width": "1280", "X-Frame-Height": "720" },
          });
        }
        return new Response("not found", { status: 404 });
      },
    });
    const flakyUrl = `http://127.0.0.1:${flakyServer.port}`;
    const { provider, find } = await openProvider(pi.url, flakyUrl);
    const screen = find("screen.capture");

    // 1) Two transient 503s followed by 200 OK -> succeeds after ~500ms (2 * 250ms default backoff).
    const t0 = Date.now();
    const recovered = await screen.execute({}, context());
    const elapsed = Date.now() - t0;
    expect(captureCalls).toBe(3);
    expect(elapsed).toBeGreaterThanOrEqual(470);
    expect((recovered.result.structuredContent as unknown as CaptureOutput).sourceSequence).toBe(11);

    // 2) Abort during 503 backoff cancels immediately without further retries.
    captureCalls = 0;
    const abortController = new AbortController();
    setTimeout(() => abortController.abort(new Error("caller aborted")), 80);
    await expect(screen.execute({}, { signal: abortController.signal })).rejects.toThrow();
    expect(captureCalls).toBe(1);

    // 3) Non-transient HTTP 500 fails immediately on first attempt without retry delay.
    mode = "hard-500";
    captureCalls = 0;
    const t500 = Date.now();
    await expect(screen.execute({}, context())).rejects.toThrow("Capture service returned HTTP 500");
    expect(captureCalls).toBe(1);
    expect(Date.now() - t500).toBeLessThan(150);

    // 4) Transient ECONNREFUSED while capture daemon restarts -> recovers once port comes back.
    provider.close();
    flakyServer.stop(true);
    const restartProbe = Bun.serve({ port: 0, fetch: () => new Response("probe") });
    const restartPort = restartProbe.port!;
    restartProbe.stop(true);
    const restartUrl = `http://127.0.0.1:${restartPort}`;
    const restartedProvider = await createSwitch2Provider({
      clock,
      piUrl: pi.url,
      captureUrl: restartUrl,
      client: new PiClient({ piUrl: pi.url, sshTunnel: false }),
      spawnCapture: false,
    });
    const restartScreen = restartedProvider.capabilities.controllers.find(item => item.tool.name === "screen.capture")!;
    let rebornServer: ReturnType<typeof Bun.serve> | undefined;
    const timer = setTimeout(() => {
      rebornServer = Bun.serve({
        port: restartPort,
        fetch() {
          return new Response(jpegBytes, {
            headers: { "Content-Type": "image/jpeg", "X-Frame-Sequence": "42", "X-Frame-Width": "1920", "X-Frame-Height": "1080" },
          });
        },
      });
    }, 100);
    try {
      const shotAfterRestart = await restartScreen.execute({}, context());
      expect((shotAfterRestart.result.structuredContent as unknown as CaptureOutput).sourceSequence).toBe(42);
    } finally {
      clearTimeout(timer);
      rebornServer?.stop(true);
      restartedProvider.close();
      pi.close();
    }
  });

  test("idle pad.release clears Pi controls, and warming-up existing capture daemon is reused without duplicate spawn", async () => {
    const pi = startMockPi();
    let daemonReady = false;
    const existingDaemon = Bun.serve({
      port: 0,
      fetch(req) {
        const url = new URL(req.url);
        if (url.pathname === "/status") {
          return Response.json({
            ok: daemonReady,
            headless: true,
            width: 1920,
            height: 1080,
            fps: daemonReady ? 60 : 0,
            frameSequence: daemonReady ? 9 : 0,
          });
        }
        return new Response("not found", { status: 404 });
      },
    });
    setTimeout(() => { daemonReady = true; }, 220);

    try {
      // Passing a non-existent captureBinary proves ensureCaptureService attaches to existingDaemon instead of spawning!
      const provider = await createSwitch2Provider({
        clock,
        piUrl: pi.url,
        captureUrl: `http://127.0.0.1:${existingDaemon.port}`,
        client: new PiClient({ piUrl: pi.url, sshTunnel: false }),
        spawnCapture: true,
        captureBinary: "/nonexistent/switch2-capture-must-not-spawn",
      });
      const release = provider.capabilities.controllers.find(item => item.tool.name === "pad.release")!;
      await release.acquire?.("epoch-idle");
      const out = await release.execute({}, context("epoch-idle"));
      expect(out.status).toBe("completed");
      expect(pi.requests.some(request => request.path === "/release")).toBe(true);
      provider.close();
    } finally {
      existingDaemon.stop(true);
      pi.close();
    }
  });
});
