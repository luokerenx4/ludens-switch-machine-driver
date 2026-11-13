import type { Clock } from "./contracts.ts";
import type { DriverProvider } from "./registration.ts";
import { createSwitch2Provider } from "./provider.ts";

export { createSwitch2Provider };
export type { DriverProvider };

/** Importing the package describes the driver; it never touches hardware. */
const registration = {
  id: "switch2",
  version: "0.1.0",
  fallbackVersion: "0.1.0",
  transport: "bridge" as const,
  defaultPort: 18765,
  needsGame: false,
  launchHint: "Connect Switch 2 HDMI to a USB capture card (auto-detects UVC cards like Hagibis / UGREEN) and ensure Pi 5 (grand@ludens-pi.local) is reachable over SSH.",
  load: async (options: { port?: number; clock: Clock }): Promise<DriverProvider> =>
    createSwitch2Provider({ port: options.port, clock: options.clock }),
};

export default registration;
export { registration, registration as driver };
