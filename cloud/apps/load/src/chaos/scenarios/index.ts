import { registerScenario } from "../runner.js";
import { clockSkewScenario } from "./clockSkew.js";
import { diskPressureScenario } from "./diskPressure.js";
import { gatewayRestartScenario } from "./gatewayRestart.js";
import { postgresRestartScenario } from "./postgresRestart.js";
import { redisQRestartScenario } from "./redisQRestart.js";
import { workerKillScenario } from "./workerKill.js";

/**
 * The registry Task 6 ships; Task 7 adds worker-kill / disk-pressure /
 * clock-skew here. The CLI's `all` mode runs every registered scenario in
 * this order (the three Task-6 scenarios first, then the Task-7 suite).
 */
registerScenario(redisQRestartScenario);
registerScenario(gatewayRestartScenario);
registerScenario(postgresRestartScenario);
registerScenario(workerKillScenario);
registerScenario(diskPressureScenario);
registerScenario(clockSkewScenario);

export {
  clockSkewScenario,
  diskPressureScenario,
  gatewayRestartScenario,
  postgresRestartScenario,
  redisQRestartScenario,
  workerKillScenario,
};
