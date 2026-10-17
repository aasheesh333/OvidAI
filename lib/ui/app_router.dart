import 'dart:async';

import 'package:flutter/material.dart';

import '../core/cloud/cloud_session_store.dart';
import '../core/distribution.dart';
import '../core/share_link_resolver.dart'
    show ShareLinkResolver, ShareViewerRoute;
import '../core/state.dart';
import 'browser_screen.dart';
import 'schedule_screen.dart';
import 'settings_screen.dart';
import 'shared_conversation_screen.dart';

/// Root navigator of the app (single [MaterialApp]).
final appNavigatorKey = GlobalKey<NavigatorState>();

/// Root scaffold messenger, so routing feedback ("Chat not found") shows no
/// matter which screen is on top.
final appScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// A destination inside the app (07 §1). Path forms:
/// `/`, `/c/:sessionId`, `/s/:token`, `/settings`, `/schedule/:sessionId`,
/// `/browser`.
sealed class AppRoute {
  const AppRoute();
}

class HomeRoute extends AppRoute {
  const HomeRoute();
}

class ChatRoute extends AppRoute {
  const ChatRoute(this.sessionId);
  final String sessionId;
}

class SharedChatRoute extends AppRoute {
  const SharedChatRoute(this.token);
  final String token;
}

class SettingsRoute extends AppRoute {
  const SettingsRoute();
}

class ScheduleRoute extends AppRoute {
  const ScheduleRoute(this.sessionId);
  final String sessionId;
}

class BrowserRoute extends AppRoute {
  const BrowserRoute();
}

/// Hand-rolled router: parses paths and App Links into [AppRoute]s and
/// opens them on the root navigator. Notification taps and App Links go
/// through [go], which first returns to the chat root (`popUntil(isFirst)`)
/// so the target is actually visible even when Settings, the browser or a
/// sheet was on top, and which validates session ids.
class AppRouter {
  AppRouter._();

  static final _sessionId = RegExp(r'^[A-Za-z0-9_\-:.]{1,128}$');

  /// Parse a path (`/c/abc`) or an `https://ovidsi.com/...` link. Share
  /// links are delegated to [ShareLinkResolver]. Returns null for anything
  /// that is not an app destination.
  static AppRoute? parse(Uri uri) {
    final share = ShareLinkResolver.route(uri);
    if (share is ShareViewerRoute) return SharedChatRoute(share.token);
    if (uri.hasScheme) {
      final host = uri.host.toLowerCase();
      if (uri.scheme != 'https' ||
          (host != 'ovidsi.com' && host != 'www.ovidsi.com')) {
        return null;
      }
    }
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return const HomeRoute();
    String? id() => segments.length == 2 && _sessionId.hasMatch(segments[1])
        ? segments[1]
        : null;
    return switch (segments.first) {
      'c' when id() != null => ChatRoute(id()!),
      'schedule' when id() != null => ScheduleRoute(id()!),
      'settings' when segments.length == 1 => const SettingsRoute(),
      'browser' when segments.length == 1 => const BrowserRoute(),
      _ => null,
    };
  }

  /// `MaterialApp.onGenerateRoute`: named pushes of pushable pages. Chat
  /// routes are not pages (the chat lives in the shell root); use [go].
  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    final route = parse(Uri.parse(settings.name ?? ''));
    final page = route == null ? null : _pageFor(route);
    if (page == null) return null;
    return MaterialPageRoute(builder: (_) => page, settings: settings);
  }

  static Widget? _pageFor(AppRoute route) => switch (route) {
    SharedChatRoute(:final token) => SharedConversationScreen(token: token),
    SettingsRoute() => const SettingsScreen(),
    BrowserRoute() => const BrowserScreen(),
    ScheduleRoute(:final sessionId) => ScheduleScreen(sessionId: sessionId),
    HomeRoute() || ChatRoute() => null,
  };

  /// Open [route] on [navigatorKey] (default: the app's root navigator).
  /// Returns false when the navigator is not attached yet or the target
  /// does not exist (a "Chat not found" snackbar is shown).
  static bool go(
    AppRoute route, {
    GlobalKey<NavigatorState>? navigatorKey,
    GlobalKey<ScaffoldMessengerState>? messengerKey,
  }) {
    final navigator = (navigatorKey ?? appNavigatorKey).currentState;
    if (navigator == null) return false;
    void notFound() {
      final messenger =
          (messengerKey ?? appScaffoldMessengerKey).currentState ??
          ScaffoldMessenger.maybeOf(navigator.context);
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Chat not found — it may have been deleted.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    switch (route) {
      case HomeRoute():
        navigator.popUntil((r) => r.isFirst);
        return true;
      case ChatRoute(:final sessionId):
        if (AppState.I.sessionById(sessionId) == null) {
          // P8 Task 10: `/c/<id>` accepts SERVER ids on the thin client —
          // a server row not yet reconciled into AppState (a cold-start
          // notification tap) triggers the reconciliation now; the tap
          // itself still reports not-found and the next open lands once
          // the list has loaded.
          if (Distribution.cloudExecution) {
            unawaited(
              CloudSessionStore.I.ready
                  .then((_) => CloudSessionStore.I.refreshSessions())
                  .catchError((Object _) {}),
            );
          }
          notFound();
          return false;
        }
        navigator.popUntil((r) => r.isFirst);
        AppState.I.selectSession(sessionId);
        return true;
      case ScheduleRoute(:final sessionId):
        if (AppState.I.sessionById(sessionId) == null) {
          notFound();
          return false;
        }
        navigator.popUntil((r) => r.isFirst);
        AppState.I.selectSession(sessionId);
        navigator.push(
          MaterialPageRoute(
            builder: (_) => ScheduleScreen(sessionId: sessionId),
            settings: RouteSettings(name: '/schedule/$sessionId'),
          ),
        );
        return true;
      case SharedChatRoute() || SettingsRoute() || BrowserRoute():
        final page = _pageFor(route)!;
        if (route is! SharedChatRoute) navigator.popUntil((r) => r.isFirst);
        navigator.push(MaterialPageRoute(builder: (_) => page));
        return true;
    }
  }

  /// Notification tap → that chat, visible.
  static bool openChat(
    String sessionId, {
    GlobalKey<NavigatorState>? navigatorKey,
    GlobalKey<ScaffoldMessengerState>? messengerKey,
  }) => go(
    ChatRoute(sessionId),
    navigatorKey: navigatorKey,
    messengerKey: messengerKey,
  );
}
