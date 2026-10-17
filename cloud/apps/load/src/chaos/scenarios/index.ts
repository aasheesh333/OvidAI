import { registerScenario } from "../runner.js";
import { gatewayRestartScenario } from "./gatewayRestart.js";
import { postgresRestartScenario } from "./postgresRestart.js";
import { redisQRestartScenario } from "./redisQRestart.js";

/**
 * The registry Task 6 ships. Task 7 adds worker-kill / disk-pressure /
 * clock-skew here; the CLI's `all` mode runs every registered scenario in
 * this order.
 */
registerScenario(redisQRestartScenario);
registerScenario(gatewayRestartScenario);
registerScenario(postgresRestartScenario);

export { gatewayRestartScenario, postgresRestartScenario, redisQRestartScenario };
