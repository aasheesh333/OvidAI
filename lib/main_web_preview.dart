import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ui/design/o_theme.dart';
import 'ui/design/o_tokens.dart';
import 'ui/v2/v2_gallery.dart';
import 'ui/v2/v2_registry_web.dart';
import 'ui/v2/v2_screen_entry.dart';

/// Web preview entrypoint.
///
/// The production app cannot compile for web: it links native libraries
/// (sqlite3, secure storage, FCM, webview). This entrypoint loads **only** the
/// design system and the v2 screen gallery, so every screen can be reviewed in
/// a browser — light and dark, at phone or tablet width — without any native
/// dependency.
///
/// Run with:
///   flutter run -d web-server -t lib/main_web_preview.dart --web-port 8080
/// or build a static copy with:
///   flutter build web --release -t lib/main_web_preview.dart
///
/// A link can open one screen at a chosen width and theme, so a reviewer can
/// share exactly what they mean:
///   ?screen=live_chat&w=412&theme=dark
void main() => runApp(const OvidWebPreview());

/// The frame widths a reviewer can put the UI through.
///
/// 360 dp is the small-Android baseline, 412 dp a modern phone and 800 dp a
/// small tablet / split-window layout. Every screen is expected to survive all
/// three plus a 2× text scale.
enum PreviewWidth {
  phone('360', 'Phone', 360),
  largePhone('412', 'Large phone', 412),
  tablet('800', 'Tablet', 800);

  const PreviewWidth(this.label, this.description, this.value);

  /// Short visible label, also used by the toggle.
  final String label;

  /// Spoken description for accessibility.
  final String description;

  /// Width of the framed surface in logical pixels.
  final double value;

  /// Reads the `w` query parameter, for example `?w=800`.
  static PreviewWidth fromQuery(String? raw) {
    final value = double.tryParse((raw ?? '').trim());
    if (value == null) return PreviewWidth.phone;
    for (final option in PreviewWidth.values) {
      if (option.value == value) return option;
    }
    return PreviewWidth.phone;
  }
}

class OvidWebPreview extends StatefulWidget {
  const OvidWebPreview({super.key});

  @override
  State<OvidWebPreview> createState() => _OvidWebPreviewState();
}

class _OvidWebPreviewState extends State<OvidWebPreview> {
  PreviewWidth _width = PreviewWidth.phone;
  ThemeMode _mode = ThemeMode.system;
  final _navigator = GlobalKey<NavigatorState>();

  /// Deep links so a reviewer can send a teammate straight to one screen:
  /// `?screen=live_chat&w=412&theme=dark`. All three are optional.
  V2ScreenEntry? _deepLink;

  @override
  void initState() {
    super.initState();
    final query = Uri.base.queryParameters;
    _width = PreviewWidth.fromQuery(query['w']);
    _mode = switch (query['theme']) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    final id = query['screen'];
    if (id != null && id.isNotEmpty) {
      for (final entry in v2ScreensWeb) {
        if (entry.id == id) {
          _deepLink = entry;
          break;
        }
      }
    }
    if (_deepLink != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openDeepLink());
    }
  }

  void _openDeepLink() {
    final entry = _deepLink;
    final navigator = _navigator.currentState;
    if (entry == null || navigator == null) return;
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => V2PreviewPage(entry: entry)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ovid Si — UI v2 preview',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigator,
      theme: OTheme.light(),
      darkTheme: OTheme.dark(),
      themeMode: _mode,
      builder: (context, child) => _PreviewShell(
        width: _width,
        mode: _mode,
        screenCount: v2ScreensWeb.length,
        onWidthChanged: (value) => setState(() => _width = value),
        onModeChanged: (value) => setState(() => _mode = value),
        child: child ?? const SizedBox.shrink(),
      ),
      home: V2GalleryPage(screens: v2ScreensWeb),
    );
  }
}

/// Window chrome around the gallery: brand, width toggle, theme toggle and the
/// framed surface itself.
///
/// The frame overrides [MediaQuery] so every pushed route is laid out at the
/// selected dp width, not at the browser's width — otherwise the gallery list
/// would be phone-sized while the screen inside it still looked desktop-sized.
///
/// The toolbar is a [Stack] sibling of the frame rather than a [Column] child:
/// Flutter drops the semantics of widgets that sit beside an expanded
/// `Navigator` inside a flex layout, and the controls must stay reachable by a
/// screen reader. Its height is measured once so the frame starts below it.
class _PreviewShell extends StatefulWidget {
  const _PreviewShell({
    required this.child,
    required this.width,
    required this.mode,
    required this.screenCount,
    required this.onWidthChanged,
    required this.onModeChanged,
  });

  final Widget child;
  final PreviewWidth width;
  final ThemeMode mode;
  final int screenCount;
  final ValueChanged<PreviewWidth> onWidthChanged;
  final ValueChanged<ThemeMode> onModeChanged;

  @override
  State<_PreviewShell> createState() => _PreviewShellState();
}

class _PreviewShellState extends State<_PreviewShell> {
  static const double _fallbackBarHeight = 88;

  final _barKey = GlobalKey();
  double _barHeight = _fallbackBarHeight;

  @override
  void initState() {
    super.initState();
    _measureBar();
  }

  @override
  void didUpdateWidget(covariant _PreviewShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    _measureBar();
  }

  /// The toolbar wraps to two lines on narrow browser windows, so its height
  /// is measured after paint instead of hard-coded.
  void _measureBar() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _barKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final height = box.size.height;
      if ((height - _barHeight).abs() > 0.5) {
        setState(() => _barHeight = height);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final media = MediaQuery.of(context);
    // Screens keep the browser's text scale and safe areas, but their logical
    // width always comes from the toggle.
    final targetWidth = widget.width.value;

    return ColoredBox(
      color: c.bg,
      child: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(top: _barHeight + OSpace.m),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    OSpace.l,
                    0,
                    OSpace.l,
                    OSpace.l,
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final frameWidth = math.min(
                        targetWidth,
                        math.max(240.0, constraints.maxWidth),
                      );
                      final frameHeight = math.max(
                        240.0,
                        constraints.maxHeight,
                      );
                      return Center(
                        child: Container(
                          width: frameWidth,
                          height: frameHeight,
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            color: c.surface,
                            borderRadius: BorderRadius.circular(
                              widget.width == PreviewWidth.tablet
                                  ? ORadius.xl
                                  : 28,
                            ),
                            border: Border.all(color: c.hairlineStrong),
                            boxShadow: [
                              BoxShadow(
                                color: c.scrim.withValues(alpha: 0.18),
                                blurRadius: 32,
                                offset: const Offset(0, 16),
                              ),
                            ],
                          ),
                          child: MediaQuery(
                            data: media.copyWith(
                              size: Size(frameWidth, frameHeight),
                              padding: EdgeInsets.zero,
                              viewPadding: EdgeInsets.zero,
                              viewInsets: EdgeInsets.zero,
                            ),
                            child: widget.child,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: KeyedSubtree(
                key: _barKey,
                child: _PreviewToolbar(
                  width: widget.width,
                  mode: widget.mode,
                  screenCount: widget.screenCount,
                  onWidthChanged: widget.onWidthChanged,
                  onModeChanged: widget.onModeChanged,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewToolbar extends StatelessWidget {
  const _PreviewToolbar({
    required this.width,
    required this.mode,
    required this.screenCount,
    required this.onWidthChanged,
    required this.onModeChanged,
  });

  final PreviewWidth width;
  final ThemeMode mode;
  final int screenCount;
  final ValueChanged<PreviewWidth> onWidthChanged;
  final ValueChanged<ThemeMode> onModeChanged;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        OSpace.xl,
        OSpace.m,
        OSpace.xl,
        OSpace.m,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.hairline)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final groups = <Widget>[
            _ChoiceGroup(
              label: 'Width',
              children: [
                for (final option in PreviewWidth.values)
                  _Choice(
                    label: option.label,
                    semanticLabel:
                        'Preview at ${option.value.round()} dp, '
                        '${option.description}',
                    selected: option == width,
                    onTap: () => onWidthChanged(option),
                  ),
              ],
            ),
            _ChoiceGroup(
              label: 'Theme',
              children: [
                _Choice(
                  label: 'Light',
                  semanticLabel: 'Preview in light theme',
                  icon: Icons.light_mode_outlined,
                  selected: mode == ThemeMode.light,
                  onTap: () => onModeChanged(ThemeMode.light),
                ),
                _Choice(
                  label: 'Dark',
                  semanticLabel: 'Preview in dark theme',
                  icon: Icons.dark_mode_outlined,
                  selected: mode == ThemeMode.dark,
                  onTap: () => onModeChanged(ThemeMode.dark),
                ),
                _Choice(
                  label: 'System',
                  semanticLabel: 'Follow the device theme',
                  icon: Icons.brightness_auto_outlined,
                  selected: mode == ThemeMode.system,
                  onTap: () => onModeChanged(ThemeMode.system),
                ),
              ],
            ),
          ];

          // Wide windows get one calm line. Narrow windows scroll the controls
          // sideways instead of wrapping them: the toolbar must not grow tall
          // enough to squeeze the frame at 200 % text.
          if (constraints.maxWidth >= 900) {
            return Row(
              children: [
                Expanded(child: _Brand(screenCount: screenCount)),
                const Spacer(),
                for (var i = 0; i < groups.length; i++) ...[
                  if (i > 0) const SizedBox(width: OSpace.xl),
                  groups[i],
                ],
              ],
            );
          }
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _Brand(
                  screenCount: screenCount,
                  ellipsize: false,
                  showWordmark: false,
                ),
                const SizedBox(width: OSpace.l),
                for (var i = 0; i < groups.length; i++) ...[
                  if (i > 0) const SizedBox(width: OSpace.xl),
                  groups[i],
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({
    required this.screenCount,
    this.ellipsize = true,
    this.showWordmark = true,
  });

  final int screenCount;

  /// Whether to show the "Ovid Si" wordmark beside the mark. Hidden on narrow
  /// windows so the toggles win the space.
  final bool showWordmark;

  /// Whether the wordmark may shrink. False inside a horizontal scroll view,
  /// where the row is unbounded and the text should keep its natural width.
  final bool ellipsize;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.accentFill,
            borderRadius: BorderRadius.circular(ORadius.m),
          ),
          child: Text('O', style: OType.h3.copyWith(color: c.onAccent)),
        ),
        if (showWordmark) ...[
          const SizedBox(width: OSpace.m),
          if (ellipsize) Flexible(child: _brandText(c)) else _brandText(c),
        ],
      ],
    );
  }

  Widget _brandText(OColors c) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Ovid Si',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: OType.bodyStrong.copyWith(color: c.text),
      ),
      Text(
        'UI v2 preview · $screenCount entries',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: OType.caption.copyWith(color: c.textMuted),
      ),
    ],
  );
}

class _ChoiceGroup extends StatelessWidget {
  const _ChoiceGroup({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: OType.overline.copyWith(color: c.textFaint),
        ),
        const SizedBox(height: OSpace.xs),
        Wrap(spacing: OSpace.xs, runSpacing: OSpace.xs, children: children),
      ],
    );
  }
}

/// One option in a toggle. Kept 48 dp tall so it stays a valid touch target.
class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.semanticLabel,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final String semanticLabel;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final foreground = selected ? c.onAccent : c.textMuted;
    return Semantics(
      button: true,
      selected: selected,
      label: semanticLabel,
      excludeSemantics: true,
      child: Material(
        color: selected ? c.accentFill : c.surface,
        shape: StadiumBorder(
          side: BorderSide(color: selected ? c.accentFill : c.hairlineStrong),
        ),
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: Container(
            constraints: const BoxConstraints(
              minHeight: OSpace.touch,
              minWidth: OSpace.touch,
            ),
            padding: const EdgeInsets.symmetric(horizontal: OSpace.l),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: foreground),
                  const SizedBox(width: OSpace.xs),
                ],
                Text(label, style: OType.label.copyWith(color: foreground)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
