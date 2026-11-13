import { spawn } from "node:child_process";
import type { ChildProcess } from "node:child_process";

export interface PiStateResult {
  ok: boolean;
  version?: number;
  result?: {
    state?: string;
    initialized?: boolean;
    peer?: string;
    player_lights?: number;
    buttons?: number[];
    sticks?: number[];
  };
  error?: unknown;
}

export interface PiClientOptions {
  port?: number;
  piUrl?: string;
  /** SSH auto-tunnel; defaults to enabled when the target host is 127.0.0.1. */
  sshTunnel?: boolean;
  sshTarget?: string;
  remotePort?: number;
  /** Test hook: shorten readiness polls. */
  probeTimeoutMs?: number;
  tunnelReadyTimeoutMs?: number;
  /** Optional hook to override remote service restart (used in tests). */
  onReconnect?: () => Promise<void>;
}

const isReady = (state: PiStateResult | undefined): boolean =>
  state?.ok === true && state.result?.state === "connected" && state.result?.initialized === true;

export class PiClient {
  readonly baseUrl: string;
  private readonly sshTunnel: boolean;
  private readonly sshTarget: string;
  private readonly remotePort: number;
  private readonly probeTimeoutMs: number;
  private readonly tunnelReadyTimeoutMs: number;
  private readonly onReconnect?: () => Promise<void>;
  private tunnel: ChildProcess | undefined;
  private reconnecting: Promise<PiStateResult | undefined> | undefined;

  constructor(options: PiClientOptions = {}) {
    const port = options.port ?? Number(process.env.LUDENS_SWITCH2_PORT ?? 18765);
    this.baseUrl = options.piUrl ?? process.env.LUDENS_SWITCH2_PI_URL ?? `http://127.0.0.1:${port}`;
    this.sshTarget = options.sshTarget ?? process.env.LUDENS_SWITCH2_SSH_TARGET ?? "grand@ludens-pi.local";
    this.remotePort = options.remotePort ?? Number(process.env.LUDENS_SWITCH2_REMOTE_PORT ?? 8765);
    this.probeTimeoutMs = options.probeTimeoutMs ?? 1500;
    this.tunnelReadyTimeoutMs = options.tunnelReadyTimeoutMs ?? 15_000;
    this.onReconnect = options.onReconnect;
    const host = (() => { try { return new URL(this.baseUrl).hostname; } catch { return ""; } })();
    this.sshTunnel = options.sshTunnel ?? host === "127.0.0.1";
  }

  private async request<T>(path: string, init?: RequestInit & { timeoutMs?: number }, timeoutMs = 3000): Promise<T> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), init?.timeoutMs ?? timeoutMs);
    const signal = init?.signal ? AbortSignal.any([init.signal, controller.signal]) : controller.signal;
    try {
      const response = await fetch(`${this.baseUrl}${path}`, { ...init, proxy: "", signal } as RequestInit);
      if (!response.ok) throw new Error(`Pi bridge returned HTTP ${response.status} on ${path}`);
      return await response.json() as T;
    } finally { clearTimeout(timer); }
  }

  private canAutoReconnect(): boolean {
    return Boolean(this.onReconnect) || this.sshTunnel;
  }

  async getState(timeoutMs = 3000): Promise<PiStateResult> {
    const state = await this.request<PiStateResult>("/state", { timeoutMs });
    if (state.ok && state.result?.state === "waiting" && this.canAutoReconnect()) {
      return (await this.reconnect()) ?? state;
    }
    return state;
  }

  async sendInput(buttons: readonly number[], sticks: readonly number[], timeoutMs = 3000): Promise<PiStateResult> {
    const body = JSON.stringify({ buttons: [...buttons], sticks: [...sticks] });
    let res = await this.request<PiStateResult>("/input", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
      timeoutMs,
    });
    if (res.ok && res.result?.state === "waiting" && this.canAutoReconnect()) {
      await this.reconnect();
      res = await this.request<PiStateResult>("/input", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body,
        timeoutMs,
      });
    }
    if (!res.ok || res.result?.state === "waiting") {
      throw new Error(`Pi bridge rejected /input: ${JSON.stringify(res)}`);
    }
    return res;
  }

  async release(timeoutMs = 3000): Promise<PiStateResult> {
    return this.request<PiStateResult>("/release", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: "{}", timeoutMs,
    });
  }

  private startTunnel(): void {
    if (this.tunnel) return;
    const port = new URL(this.baseUrl).port || "18765";
    const child = spawn("ssh", [
      "-o", "BatchMode=yes",
      "-o", "StrictHostKeyChecking=accept-new",
      "-o", "ExitOnForwardFailure=yes",
      "-o", "ServerAliveInterval=5",
      "-o", "ServerAliveCountMax=3",
      "-N",
      "-L", `127.0.0.1:${port}:127.0.0.1:${this.remotePort}`,
      this.sshTarget,
    ], { stdio: ["ignore", "ignore", "ignore"] });
    this.tunnel = child;
    const clear = () => { if (this.tunnel === child) this.tunnel = undefined; };
    child.on("exit", clear);
    child.on("error", clear);
  }

  private runRemoteServiceCommand(action: "start" | "restart"): Promise<void> {
    if (this.onReconnect && action === "restart") return this.onReconnect();
    const cmd = action === "restart"
      ? "sudo -n systemctl restart ludens-wireless-controller"
      : "systemctl is-active --quiet ludens-wireless-controller || sudo -n systemctl start ludens-wireless-controller";
    return new Promise(resolve => {
      const child = spawn("ssh", [
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=5",
        this.sshTarget,
        cmd,
      ], { stdio: ["ignore", "ignore", "ignore"] });
      const timer = setTimeout(() => { child.kill("SIGTERM"); resolve(); }, 8000);
      child.on("exit", () => { clearTimeout(timer); resolve(); });
      child.on("error", () => { clearTimeout(timer); resolve(); });
    });
  }

  /** Restart the wireless controller service when the Switch drops the Bluetooth link (e.g. Change Grip/Order). */
  async reconnect(timeoutMs = 12_000): Promise<PiStateResult | undefined> {
    if (this.reconnecting) return this.reconnecting;
    this.reconnecting = (async () => {
      try {
        await this.runRemoteServiceCommand("restart");
        const deadline = Date.now() + timeoutMs;
        let last: PiStateResult | undefined;
        while (Date.now() < deadline) {
          await new Promise(resolve => setTimeout(resolve, 200));
          try {
            const candidate = await this.request<PiStateResult>("/state", { timeoutMs: this.probeTimeoutMs });
            last = candidate;
            if (isReady(candidate)) return candidate;
          } catch {
            if (this.sshTunnel && !this.onReconnect && !this.tunnel) this.startTunnel();
          }
        }
        return last;
      } finally {
        this.reconnecting = undefined;
      }
    })();
    return this.reconnecting;
  }

  /** Probe /state; if unreachable or disconnected (`waiting`) and auto-tunnel is on, self-heal and wait for readiness. */
  async connect(tunnelReadyTimeoutMs = this.tunnelReadyTimeoutMs): Promise<PiStateResult> {
    let state: PiStateResult | undefined;
    try { state = await this.request<PiStateResult>("/state", { timeoutMs: this.probeTimeoutMs }); } catch { state = undefined; }
    if (!state && this.sshTunnel) {
      await this.runRemoteServiceCommand("start");
      try { state = await this.request<PiStateResult>("/state", { timeoutMs: this.probeTimeoutMs }); } catch { state = undefined; }
      if (!state) this.startTunnel();
      const deadline = Date.now() + tunnelReadyTimeoutMs;
      while (!isReady(state) && Date.now() < deadline) {
        await new Promise(resolve => setTimeout(resolve, 300));
        try {
          const candidate = await this.request<PiStateResult>("/state", { timeoutMs: this.probeTimeoutMs });
          state = candidate;
          if (isReady(candidate)) break;
        } catch { /* tunnel/service warming up */ }
      }
    }
    if (state && !isReady(state) && this.canAutoReconnect()) {
      state = await this.reconnect(tunnelReadyTimeoutMs);
    }
    if (!state) {
      throw new Error(`Switch 2 bridge unreachable at ${this.baseUrl} (SSH tunnel to ${this.sshTarget} did not become ready); is the Pi 5 running pi-pcble-bridge.py?`);
    }
    if (!isReady(state)) {
      throw new Error(`Switch 2 bridge not ready at ${this.baseUrl}: ${JSON.stringify(state)}`);
    }
    return state;
  }

  ownsTunnel(): boolean { return this.tunnel !== undefined; }

  close(): void {
    if (this.tunnel) { this.tunnel.kill("SIGTERM"); this.tunnel = undefined; }
  }
}
