import 'package:ovid_ai/ui/v2/connectors/catalog_data.dart';
import 'package:ovid_ai/ui/v2/connectors/connectors_page.dart';

import 'a11y_support.dart';

void main() {
  group('ConnectorsPage a11y', () {
    Future<void> pumpConnectors(WidgetTester tester, {double textScale = 1.0}) async {
      await pumpA11yScreen(
        tester,
        ConnectorsPage(
          data: V2ConnectorsData(
            connectors: const [
              V2Connector(
                id: 'github',
                name: 'GitHub',
                description: 'Repository access and issues.',
                category: 'Developer',
                kind: V2ConnectorKind.app,
                auth: V2CatalogAuth.oauth,
                tools: ['search_issues', 'create_pr'],
                connected: true,
                enabled: true,
              ),
              V2Connector(
                id: 'slack',
                name: 'Slack',
                description: 'Send messages to channels.',
                category: 'Communication',
                kind: V2ConnectorKind.app,
                auth: V2CatalogAuth.oauth,
                tools: ['post_message'],
                connected: false,
                enabled: false,
              ),
            ],
            useBuiltInCatalog: false,
          ),
          onToggle: (id, enabled) {},
          onOpen: (_) {},
          onConnect: (_) {},
          onRetry: () {},
        ),
        textScale: textScale,
      );
    }

    testWidgets('meets a11y guidelines at 1.0, 1.5 and 2.0 text scale',
        (tester) async {
      await expectA11yAtScales(tester, 'ConnectorsPage', (scale) async {
        await pumpConnectors(tester, textScale: scale);
      });
    });

    testWidgets('no overflow at 2.0 text scale', (tester) async {
      await pumpConnectors(tester, textScale: 2.0);
      expect(tester.takeException(), isNull);
    });
  });
}
