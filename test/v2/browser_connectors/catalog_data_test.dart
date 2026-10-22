import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/v2/connectors/catalog_data.dart';

/// Ids the screens and setup flows deep-link to today. A rename here breaks
/// saved connections, so keep these anchors explicit.
const _requiredConnectors = <String>[
  'github',
  'gitlab',
  'gmail',
  'google-drive',
  'google-calendar',
  'slack',
  'notion',
  'linear',
  'jira',
  'figma',
  'dropbox',
  'stripe',
];

const _requiredAgentEntries = <String>[
  'context7',
  'superpowers',
  'filesystem',
  'fetch',
  'memory',
  'puppeteer',
  'postgres',
];

void main() {
  group('catalog shape', () {
    test('lists at least 120 integrations', () {
      expect(v2Catalog.length, greaterThanOrEqualTo(120));
    });

    test('uses unique, url-safe ids', () {
      final seen = <String>{};
      final slug = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');
      for (final entry in v2Catalog) {
        expect(
          seen.add(entry.id),
          isTrue,
          reason: 'duplicate id "${entry.id}"',
        );
        expect(
          slug.hasMatch(entry.id),
          isTrue,
          reason: '"${entry.id}" must be a lower-case slug',
        );
      }
    });

    test('uses unique display names ignoring case and padding', () {
      final seen = <String>{};
      for (final entry in v2Catalog) {
        final normalized = entry.name.trim().toLowerCase();
        expect(normalized, isNotEmpty, reason: entry.id);
        expect(
          seen.add(normalized),
          isTrue,
          reason: 'duplicate name "${entry.name}"',
        );
      }
    });

    test('every entry has complete, display-ready copy', () {
      for (final entry in v2Catalog) {
        expect(entry.name.trim(), entry.name, reason: entry.id);
        expect(entry.description.trim(), entry.description, reason: entry.id);
        expect(entry.category.trim(), entry.category, reason: entry.id);
        expect(
          entry.description.length,
          greaterThanOrEqualTo(20),
          reason: '${entry.id} description is too terse',
        );
        expect(
          entry.description.length,
          lessThanOrEqualTo(100),
          reason: '${entry.id} description is too long for one row',
        );
      }
    });

    test('covers connectors, plugins, and MCP servers', () {
      final stats = v2CatalogStats;
      expect(stats.connectors, greaterThanOrEqualTo(60));
      expect(stats.plugins, greaterThanOrEqualTo(20));
      expect(stats.mcp, greaterThanOrEqualTo(20));
      expect(stats.connectors + stats.plugins + stats.mcp, stats.total);
    });

    test('groups kinds in catalog order', () {
      var highest = -1;
      for (final entry in v2Catalog) {
        final index = V2CatalogKind.values.indexOf(entry.kind);
        expect(
          index,
          greaterThanOrEqualTo(highest),
          reason: '${entry.id} breaks the connector → plugin → MCP order',
        );
        highest = index;
      }
    });

    test('every kind, auth, and risk value is represented', () {
      for (final kind in V2CatalogKind.values) {
        expect(
          v2Catalog.any((entry) => entry.kind == kind),
          isTrue,
          reason: 'missing kind ${kind.name}',
        );
      }
      for (final auth in V2CatalogAuth.values) {
        expect(
          v2Catalog.any((entry) => entry.auth == auth),
          isTrue,
          reason: 'missing auth ${auth.name}',
        );
      }
      for (final risk in V2CatalogRisk.values) {
        expect(
          v2Catalog.any((entry) => entry.risk == risk),
          isTrue,
          reason: 'missing risk ${risk.name}',
        );
      }
    });

    test('every connector declares how it authenticates', () {
      for (final entry in v2Catalog.where((entry) => entry.isConnector)) {
        expect(
          entry.auth,
          isNot(V2CatalogAuth.none),
          reason: '${entry.id} is a hosted connector without auth',
        );
        expect(entry.requiresCredentials, isTrue, reason: entry.id);
      }
    });

    test('local plugins and MCP servers can run without secrets', () {
      final keyless = v2Catalog.where(
        (entry) => !entry.isConnector && entry.auth == V2CatalogAuth.none,
      );
      expect(keyless, isNotEmpty);
      for (final entry in keyless) {
        expect(entry.requiresCredentials, isFalse, reason: entry.id);
      }
    });

    test('categories are trimmed, unique, and alphabetized', () {
      for (final entry in v2Catalog) {
        expect(entry.category, entry.category.trim(), reason: entry.id);
        expect(entry.category, isNot(contains('  ')), reason: entry.id);
      }
      final categories = v2CatalogCategories;
      final lowered = categories.map((c) => c.toLowerCase()).toList();
      expect(lowered.toSet().length, lowered.length);
      final sorted = [...lowered]..sort();
      expect(lowered, sorted);
      expect(categories.length, greaterThanOrEqualTo(15));
    });

    test('ships both first-party and third-party entries', () {
      final stats = v2CatalogStats;
      expect(stats.builtIn, greaterThan(0));
      expect(stats.custom, greaterThan(0));
      expect(stats.builtIn + stats.custom, stats.total);
      expect(
        v2Catalog.where((entry) => !entry.builtIn && entry.isMcp),
        isNotEmpty,
        reason: 'community MCP servers should stay flagged',
      );
      for (final entry in v2Catalog.where((entry) => entry.isConnector)) {
        expect(entry.builtIn, isTrue, reason: entry.id);
      }
    });

    test('contains the connector anchors the app deep-links to', () {
      for (final id in _requiredConnectors) {
        final entry = v2CatalogEntryById(id);
        expect(entry, isNotNull, reason: 'missing connector $id');
        expect(entry!.kind, V2CatalogKind.connector, reason: id);
      }
    });

    test('contains the plugin and MCP anchors the agent relies on', () {
      for (final id in _requiredAgentEntries) {
        expect(v2CatalogEntryById(id), isNotNull, reason: 'missing $id');
      }
      expect(v2CatalogEntryById('superpowers')!.kind, V2CatalogKind.plugin);
      for (final id in [
        'context7',
        'filesystem',
        'fetch',
        'memory',
        'puppeteer',
        'postgres',
      ]) {
        expect(v2CatalogEntryById(id)!.kind, V2CatalogKind.mcp, reason: id);
      }
    });

    test('records realistic auth and risk for high-stakes entries', () {
      expect(v2CatalogEntryById('github')!.auth, V2CatalogAuth.oauth);
      expect(v2CatalogEntryById('stripe')!.auth, V2CatalogAuth.apiKey);
      expect(v2CatalogEntryById('stripe')!.risk, V2CatalogRisk.high);
      expect(
        v2CatalogEntryById('postgres')!.auth,
        V2CatalogAuth.connectionString,
      );
      expect(v2CatalogEntryById('postgres')!.risk, V2CatalogRisk.high);
      expect(v2CatalogEntryById('filesystem')!.auth, V2CatalogAuth.none);
      expect(v2CatalogEntryById('context7')!.risk, V2CatalogRisk.low);
      expect(v2CatalogEntryById('github')!.risk, V2CatalogRisk.medium);
    });

    test('entries compare by stable id', () {
      final original = v2CatalogEntryById('github')!;
      final copy = V2CatalogEntry(
        id: 'github',
        name: 'GitHub',
        description: 'Repositories, issues, pull requests, and Actions runs.',
        category: 'Code',
        kind: V2CatalogKind.connector,
        auth: V2CatalogAuth.oauth,
        risk: V2CatalogRisk.medium,
      );
      expect(copy, original);
      expect(copy.hashCode, original.hashCode);
      expect(copy, isNot(v2CatalogEntryById('gitlab')));
      expect(copy.toString(), contains('github'));
    });
  });

  group('catalog queries', () {
    test('lookup by id trims and ignores case', () {
      final github = v2CatalogEntryById('github');
      expect(github, isNotNull);
      expect(v2CatalogEntryById(' GitHub '), same(github));
      expect(v2CatalogEntryById('GITHUB'), same(github));
    });

    test('lookup returns null for empty and unknown ids', () {
      expect(v2CatalogEntryById(''), isNull);
      expect(v2CatalogEntryById('   '), isNull);
      expect(v2CatalogEntryById('not-a-real-connector'), isNull);
    });

    test('kind lookup preserves catalog order', () {
      final plugins = v2CatalogEntriesOfKind(V2CatalogKind.plugin);
      final expected = v2Catalog
          .where((entry) => entry.kind == V2CatalogKind.plugin)
          .map((entry) => entry.id)
          .toList();
      expect(plugins.map((entry) => entry.id).toList(), expected);
      expect(plugins.length, v2CatalogStats.plugins);
    });

    test('category lookup is case-insensitive and trims', () {
      final code = v2CatalogEntriesInCategory('  cOdE ');
      expect(code, isNotEmpty);
      for (final entry in code) {
        expect(entry.category.toLowerCase(), 'code');
      }
      expect(
        v2CatalogEntriesInCategory('code').map((entry) => entry.id),
        code.map((entry) => entry.id),
      );
    });

    test('unknown category returns an empty list', () {
      expect(v2CatalogEntriesInCategory(''), isEmpty);
      expect(v2CatalogEntriesInCategory('No Such Category'), isEmpty);
    });

    test('query results are immutable', () {
      expect(
        () => v2CatalogEntriesOfKind(
          V2CatalogKind.connector,
        ).add(v2Catalog.first),
        throwsUnsupportedError,
      );
      expect(
        () => v2CatalogEntriesInCategory('Code').add(v2Catalog.first),
        throwsUnsupportedError,
      );
      expect(
        () => searchV2Catalog('').add(v2Catalog.first),
        throwsUnsupportedError,
      );
      expect(() => v2CatalogCategories.add('Nope'), throwsUnsupportedError);
    });

    test('empty search returns the whole catalog in order', () {
      expect(
        searchV2Catalog('').map((entry) => entry.id),
        v2Catalog.map((entry) => entry.id),
      );
      expect(searchV2Catalog('   ').length, v2Catalog.length);
    });

    test('search matches ids, names, descriptions, and categories', () {
      expect(
        searchV2Catalog('github').map((entry) => entry.id),
        containsAll(<String>['github', 'github-mcp']),
      );
      expect(
        searchV2Catalog('refund').map((entry) => entry.id),
        contains('stripe'),
      );
      expect(
        searchV2Catalog('payments').map((entry) => entry.id),
        containsAll(<String>['stripe', 'paypal', 'square']),
      );
      expect(
        searchV2Catalog('add-on').map((entry) => entry.id),
        contains('context7'),
      );
    });

    test('search is case-insensitive and ANDs every term', () {
      final lower = searchV2Catalog('google drive');
      final upper = searchV2Catalog('GOOGLE DRIVE');
      expect(lower.map((entry) => entry.id), upper.map((entry) => entry.id));
      expect(lower.map((entry) => entry.id), contains('google-drive'));
      expect(lower.map((entry) => entry.id), isNot(contains('google-docs')));
      expect(searchV2Catalog('stripe kubernetes'), isEmpty);
      expect(
        searchV2Catalog('stripe refunds').map((entry) => entry.id),
        contains('stripe'),
      );
    });

    test('search returns nothing for gibberish', () {
      expect(searchV2Catalog('zzzz-no-such-integration'), isEmpty);
    });

    test('stats agree with the catalog', () {
      final stats = v2CatalogStats;
      expect(stats.total, v2Catalog.length);
      expect(
        stats.connectors,
        v2Catalog.where((entry) => entry.isConnector).length,
      );
      expect(stats.plugins, v2Catalog.where((entry) => entry.isPlugin).length);
      expect(stats.mcp, v2Catalog.where((entry) => entry.isMcp).length);
      expect(
        stats.highRisk,
        v2Catalog.where((entry) => entry.risk == V2CatalogRisk.high).length,
      );
      expect(stats.pluginsAndMcp, stats.plugins + stats.mcp);
      expect(stats.total, stats.connectors + stats.pluginsAndMcp);
    });

    test('stats for a subset count only that subset', () {
      final connectors = v2CatalogEntriesOfKind(V2CatalogKind.connector);
      final stats = V2CatalogStats.from(connectors);
      expect(stats.total, connectors.length);
      expect(stats.connectors, connectors.length);
      expect(stats.plugins, 0);
      expect(stats.mcp, 0);
      expect(stats.builtIn, connectors.length);
      expect(stats.custom, 0);
    });

    test('stats for an empty catalog are all zero', () {
      final stats = V2CatalogStats.from(const <V2CatalogEntry>[]);
      expect(stats.total, 0);
      expect(stats.connectors, 0);
      expect(stats.plugins, 0);
      expect(stats.mcp, 0);
      expect(stats.builtIn, 0);
      expect(stats.custom, 0);
      expect(stats.highRisk, 0);
      expect(stats.pluginsAndMcp, 0);
    });
  });

  group('presentation helpers', () {
    test('kinds expose labels and catalog section titles', () {
      expect(V2CatalogKind.connector.label, 'Connector');
      expect(V2CatalogKind.plugin.label, 'Plugin');
      expect(V2CatalogKind.mcp.label, 'Add-on');
      expect(V2CatalogKind.connector.sectionTitle, 'Connectors');
      expect(V2CatalogKind.plugin.sectionTitle, 'Plugins & add-ons');
      expect(V2CatalogKind.mcp.sectionTitle, 'Plugins & add-ons');
    });

    test('auth labels and secret requirements are complete', () {
      for (final auth in V2CatalogAuth.values) {
        expect(auth.label.trim(), isNotEmpty);
      }
      expect(V2CatalogAuth.none.needsSecret, isFalse);
      for (final auth in V2CatalogAuth.values) {
        if (auth != V2CatalogAuth.none) {
          expect(auth.needsSecret, isTrue, reason: auth.name);
        }
      }
    });

    test('risk badges have a short label and plain-language summary', () {
      for (final risk in V2CatalogRisk.values) {
        expect(risk.label.trim(), isNotEmpty);
        expect(risk.summary.trim(), isNotEmpty);
        expect(risk.summary.endsWith('.'), isTrue);
      }
      expect(V2CatalogRisk.high.summary, contains('money'));
      expect(V2CatalogRisk.low.summary, contains('Read-only'));
    });

    test('entry display helpers follow the kind', () {
      final github = v2CatalogEntryById('github')!;
      expect(github.isConnector, isTrue);
      expect(github.isPlugin, isFalse);
      expect(github.isMcp, isFalse);
      expect(github.sectionTitle, 'Connectors');

      final superpowers = v2CatalogEntryById('superpowers')!;
      expect(superpowers.isPlugin, isTrue);
      expect(superpowers.sectionTitle, 'Plugins & add-ons');

      final postgres = v2CatalogEntryById('postgres')!;
      expect(postgres.isMcp, isTrue);
      expect(postgres.sectionTitle, 'Plugins & add-ons');
    });
  });
}
