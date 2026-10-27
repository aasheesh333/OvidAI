import 'cloud_rest.dart';
import 'trajectory_client.dart' as legacy;

export 'trajectory_client.dart'
    show TrajectoryController, TrajectoryEventPage, TrajectoryTimerFactory;
export 'trajectory_projection.dart';

/// Stable import for the trajectory screens. The adapter lives beside the
/// controller and reads the gateway's actual `/events` and `/subagents`
/// contracts, with capability fallback for older deployments.
class TrajectoryApi extends legacy.TrajectoryApi {
  TrajectoryApi([CloudRestClient? rest]) : super(rest ?? CloudRestClient.I);
}
