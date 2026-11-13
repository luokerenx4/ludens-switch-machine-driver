import type { Clock, ControllerContext, ExecutionResult, ToolArguments, ToolExecutionResult } from "./contracts.ts";
import type { PiClient } from "./pi-client.ts";
import { structuredResult, toolExecution } from "./tool-contract.ts";
import { encodeSpanState } from "./calibration.ts";
import type { Span } from "./timeline.ts";

type ActionStatus = "running" | ExecutionResult["status"];
interface Action {
  id: string;
  epoch: string;
  status: ActionStatus;
  requestedAtMs: number;
  receivedAtMs?: number;
  output?: unknown;
  error?: string;
  interruptRequested?: boolean;
  abortController: AbortController;
  done: Promise<void>;
}

export const KEEPALIVE_INTERVAL_MS = 100;
const KEEPALIVE_MIN_REMAINING_MS = 20;

/**
 * One pad action per device. The Pi C backend auto-releases inputs after 500ms
 * of silence, so each span's POST /input is re-sent every 100ms until it ends.
 * Only controlSignal abort, pad.cancel, pad.release or release(epoch) cancels a
 * running action; a caller's own wait signal never does.
 */
export function createPadPlayer(options: {
  client: PiClient; clock: Clock;
  keepaliveIntervalMs?: number;
  owns: (epoch: string) => boolean;
}) {
  const { client, clock } = options;
  const keepaliveMs = options.keepaliveIntervalMs ?? KEEPALIVE_INTERVAL_MS;
  const actions = new Map<string, Action>();
  let active: Action | undefined;
  const payload = (action: Action) => ({ actionId: action.id, status: action.status,
    timing: { clock: clock.id, submittedAtMs: action.requestedAtMs, completedAtMs: action.receivedAtMs },
    ...(action.output as Record<string, unknown> | undefined), ...(action.error ? { error: action.error } : {}) });

  /** Abortable sleep: resolves false immediately when aborted, true on natural timeout. */
  const sleep = (ms: number, signal: AbortSignal): Promise<boolean> => {
    if (signal.aborted) return Promise.resolve(false);
    return new Promise<boolean>(resolve => {
      const onAbort = () => {
        clearTimeout(timer);
        resolve(false);
      };
      const timer = setTimeout(() => {
        signal.removeEventListener("abort", onAbort);
        resolve(true);
      }, Math.max(1, ms));
      signal.addEventListener("abort", onAbort, { once: true });
    });
  };

  async function wait(action: Action, signal: AbortSignal) {
    signal.throwIfAborted();
    const { promise, reject } = Promise.withResolvers<never>();
    const abort = () => reject(signal.reason ?? new Error("Wait cancelled"));
    signal.addEventListener("abort", abort, { once: true });
    try { await Promise.race([action.done, promise]); }
    finally { signal.removeEventListener("abort", abort); }
  }

  /** Interrupt the running action from control paths (cancel/release/epoch loss). */
  async function interrupt(reason: string) {
    if (!active || active.status !== "running") return;
    active.error = active.error ?? reason;
    active.interruptRequested = true;
    active.abortController.abort(reason);
    await client.release().catch(() => {});
  }

  async function runSpans(action: Action, spans: Span[], context: ControllerContext) {
    let interrupted = false;
    const aborted = () =>
      context.controlSignal?.aborted === true
      || action.status !== "running"
      || action.interruptRequested === true
      || action.abortController.signal.aborted;
    const abort = () => {
      if (active === action && action.status === "running") {
        interrupted = true;
        action.abortController.abort("controlSignal");
      }
    };
    context.controlSignal?.addEventListener("abort", abort, { once: true });
    let inputWrites = 0;
    try {
      let spanDeadline = clock.now();
      for (const span of spans) {
        if (aborted()) break;
        spanDeadline = Math.max(clock.now(), spanDeadline) + span.durationMs;
        const { buttons, sticks } = encodeSpanState(span.state);
        await client.sendInput(buttons, sticks);
        inputWrites++;
        while (!aborted()) {
          const remaining = spanDeadline - clock.now();
          if (remaining <= 0) break;
          const slice = Math.min(keepaliveMs, remaining);
          const ok = await sleep(slice, action.abortController.signal);
          if (!ok || aborted()) break;
          if (spanDeadline - clock.now() > KEEPALIVE_MIN_REMAINING_MS) {
            await client.sendInput(buttons, sticks);
            inputWrites++;
          }
        }
      }
      await client.release().catch(() => {});
      action.status = interrupted || aborted() ? "interrupted" : "completed";
      action.output = { elapsedMs: clock.now() - action.requestedAtMs, spans: spans.length, inputWrites };
    } catch (error) {
      await client.release().catch(() => {});
      action.status = aborted() ? "interrupted" : "failed";
      action.error = String(error);
    } finally {
      context.controlSignal?.removeEventListener("abort", abort);
      action.receivedAtMs = clock.now();
      active = undefined;
      while (actions.size > 64) actions.delete(actions.keys().next().value!);
      context.record?.("action_end", { ...payload(action), id: action.id,
        status: action.status,
        exitCode: action.status === "completed" ? 0 : action.status === "interrupted" ? 130 : 1,
        stdout: JSON.stringify(payload(action)), stderr: action.error ?? "",
        timing: { clock: clock.id, requestedAtMs: action.requestedAtMs, receivedAtMs: action.receivedAtMs } });
    }
  }

  return {
    async settle() { await active?.done; },
    reset() {
      if (active) throw new Error("BUSY: previous pad action has not finished releasing");
      actions.clear();
    },
    async releaseAll(_context: Pick<ControllerContext, "controlSignal" | "record">) {
      const hadActive = Boolean(active && active.status === "running");
      await interrupt("pad.release");
      await this.settle();
      if (!hadActive) await client.release();
    },
    async execute(command: string, args: ToolArguments, context: ControllerContext): Promise<ToolExecutionResult> {
      const { signal, controlSignal, epoch, record } = context;
      signal.throwIfAborted();
      if (!epoch || !options.owns(epoch)) throw new Error("STALE_EPOCH");
      const requestedAtMs = clock.now();
      let action: Action;
      if (command === "play") {
        signal.throwIfAborted();
        controlSignal?.throwIfAborted();
        if (active) throw new Error("BUSY: a pad action is already running");
        action = { id: crypto.randomUUID(), epoch, status: "running", requestedAtMs: clock.now(), abortController: new AbortController(), done: Promise.resolve() };
        active = action;
        actions.set(action.id, action);
        record?.("action_start", { ...payload(action) });
        action.done = runSpans(action, args.spans as Span[], context);
        if (args.wait === true) await wait(action, signal);
      } else if (command === "wait" || command === "status" || command === "cancel") {
        const found = actions.get(args.actionId as string);
        if (!found || found.epoch !== epoch) throw new Error("Unknown action in this control epoch (only the latest 64 results are retained)");
        action = found;
        if (command === "cancel" && action.status === "running") await interrupt("pad.cancel");
        if (command !== "status") await wait(action, signal);
      } else throw new Error("Unknown pad command; see --help");

      const terminal = command === "wait" || command === "cancel" || command === "play" && args.wait === true;
      const status = terminal && action.status !== "running" ? action.status : "completed";
      const result = structuredResult(payload(action));
      if (status !== "completed") result.isError = true;
      return toolExecution(clock, requestedAtMs, result, { actionId: action.id, status,
        readOnly: command === "status" || command === "wait",
        exitCode: status === "completed" ? 0 : status === "interrupted" ? 130 : 1,
        stdout: JSON.stringify(payload(action)), stderr: terminal ? action.error ?? "" : "" });
    },
  };
}
