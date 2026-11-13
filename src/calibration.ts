/** Physical bit order in pcble2gamepad's Pro Controller HID report (3-byte button mask). */
export const BUTTONS = [
  "A", "B", "X", "Y",
  "LSTICK", "RSTICK",
  "L", "R", "ZL", "ZR",
  "PLUS", "MINUS",
  "LEFT", "UP", "RIGHT", "DOWN",
  "HOME", "CAPTURE",
] as const;
export type ButtonName = typeof BUTTONS[number];
export const AXES = ["LX", "LY", "RX", "RY"] as const;
export type AxisName = typeof AXES[number];

const BUTTON_BITS: Record<ButtonName, [byte: number, bit: number]> = {
  Y: [0, 0x01], X: [0, 0x02], B: [0, 0x04], A: [0, 0x08], R: [0, 0x40], ZR: [0, 0x80],
  MINUS: [1, 0x01], PLUS: [1, 0x02], RSTICK: [1, 0x04], LSTICK: [1, 0x08], HOME: [1, 0x10], CAPTURE: [1, 0x20],
  DOWN: [2, 0x01], UP: [2, 0x02], RIGHT: [2, 0x04], LEFT: [2, 0x08], L: [2, 0x40], ZL: [2, 0x80],
};

/** Normalize a pressed-button list (or full record) to the 3-byte mask the Pi expects. */
export function encodeButtons(pressed: readonly ButtonName[]): [number, number, number] {
  const bytes = [0, 0, 0];
  for (const name of pressed) {
    const [byte, bit] = BUTTON_BITS[name];
    bytes[byte]! |= bit;
  }
  return bytes as [number, number, number];
}

export function decodeButtons([b0, b1, b2]: readonly number[]): Record<ButtonName, 0 | 1> {
  const bytes = [b0, b1, b2];
  return Object.fromEntries(BUTTONS.map(name => {
    const [byte, bit] = BUTTON_BITS[name];
    return [name, (bytes[byte]! & bit) !== 0 ? 1 : 0] as const;
  })) as Record<ButtonName, 0 | 1>;
}

/** Factory stick calibration from pcble2gamepad/poc/protocol.c (12-bit HID values, 0..4095). */
const CALIBRATION: Record<AxisName, { center: number; pos: number; neg: number }> = {
  LX: { center: 2159, pos: 1466, neg: 1517 },
  LY: { center: 1916, pos: 1583, neg: 1465 },
  RX: { center: 2070, pos: 1414, neg: 1522 },
  RY: { center: 2013, pos: 1510, neg: 1531 },
};

export function encodeAxis(axis: AxisName, value: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) throw new Error(`Invalid axis value: ${String(value)}`);
  const { center, pos, neg } = CALIBRATION[axis];
  let raw: number;
  if (value === 0) raw = center;
  else if (value > 0) raw = Math.round(center + value * pos);
  else raw = Math.round(center + value * neg);
  return Math.min(4095, Math.max(0, raw));
}

export function decodeAxis(axis: AxisName, raw: number): number {
  const { center, pos, neg } = CALIBRATION[axis];
  if (raw === center) return 0;
  if (raw > center) return Math.min(1, Number(((raw - center) / pos).toFixed(4)));
  return Math.max(-1, Number(((raw - center) / neg).toFixed(4)));
}

/** Encode a full pad span state `{BUTTON?: 0|1, AXIS?: -1..1}` into the POST /input payload. */
export function encodeSpanState(state: Record<string, number>): { buttons: [number, number, number]; sticks: [number, number, number, number] } {
  const buttons = [0, 0, 0];
  const sticks = [0, 1, 2, 3].map(axis => encodeAxis(AXES[axis]!, 0));
  for (const [key, value] of Object.entries(state)) {
    const bit = BUTTON_BITS[key as ButtonName];
    if (bit && (value === 0 || value === 1)) buttons[bit[0]]! |= value ? bit[1] : 0;
    else if ((AXES as readonly string[]).includes(key)
      && typeof value === "number" && Number.isFinite(value) && Math.abs(value) <= 1) {
      sticks[AXES.indexOf(key as AxisName)] = encodeAxis(key as AxisName, value);
    } else throw new Error(`Invalid channel/value: ${key}=${String(value)}`);
  }
  return { buttons: buttons as [number, number, number], sticks: sticks as [number, number, number, number] };
}

export function decodeStickPayload(sticks: readonly number[]): Record<AxisName, number> {
  return Object.fromEntries(AXES.map((axis, i) => [axis, decodeAxis(axis, Number(sticks[i]))])) as Record<AxisName, number>;
}
