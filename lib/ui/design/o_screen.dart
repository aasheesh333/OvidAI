import 'package:flutter/material.dart';

import 'o_components.dart';
import 'o_motion.dart';
import 'o_tokens.dart';

/// Breakpoints shared by every screen. Keeping them here is what makes
/// "responsive" mean the same thing on all 51 screens.
abstract final class OBreakpoints {
  /// Below this the header may keep only one action.
  static const double compact = 360;

  /// Tablet: content centres, sheets become dialogs, the drawer becomes a rail.
  static const double tablet = 600;

  /// Desktop / foldable open: a permanent navigation rail.
  static const double wide = 900;

  /// Max content width per band. A wider window adds margin, not line length.
  static double contentMaxWidth(double width) {
    if (width >= wide) return 720;
    if (width >= tablet) return 640;
    return double.infinity;
  }

  static bool isTablet(double width) => width >= tablet;
  static bool isWide(double width) => width >= wide;
  static bool isCompact(double width) => width < compact;
}

/// Reads the current width once and exposes the band decisions.
///
/// Use `LayoutBuilder` for the width that actually matters (the space a widget
/// was given); `OResponsive.of` is for page-level decisions where the window
/// width is the right question.
@immutable
class OResponsive {
  const OResponsive._(this.width, this.textScale);

  final double width;
  final double textScale;

  factory OResponsive.of(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return OResponsive._(
      size.width,
      MediaQuery.textScalerOf(context).scale(14) / 14,
    );
  }

  bool get isCompact => OBreakpoints.isCompact(width);
  bool get isTablet => OBreakpoints.isTablet(width);
  bool get isWide => OBreakpoints.isWide(width);
  double get maxContentWidth => OBreakpoints.contentMaxWidth(width);

  /// Side padding: tighter on small phones, generous on tablets.
  double get gutter => isTablet ? OSpace.xl : OSpace.l;

  /// How many header actions fit before they must collapse into a menu.
  int get headerActionBudget => isCompact ? 1 : 2;

  /// Grid columns for card lists. Rows never become columns.
  int get cardColumns {
    if (width >= 1000) return 3;
    if (isTablet) return 2;
    return 1;
  }
}

/// Centres content and caps its line length.
///
/// This is the single place the app decides how wide a page may get, so a
/// tablet does not stretch a phone layout across 1000 dp.
class OContent extends StatelessWidget {
  const OContent({
    super.key,
    required this.child,
    this.maxWidth,
    this.padding = true,
    this.alignment = Alignment.topCenter,
  });

  final Widget child;
  final double? maxWidth;
  final bool padding;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final r = OResponsive.of(context);
    final limit = maxWidth ?? r.maxContentWidth;
    final pad = padding
        ? EdgeInsets.symmetric(horizontal: r.gutter)
        : EdgeInsets.zero;
    return Align(
      alignment: alignment,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: limit.isFinite ? limit : double.infinity,
        ),
        child: Padding(padding: pad, child: child),
      ),
    );
  }
}

/// The standard page shell: one header, one centred body, one primary action.
///
/// Using this instead of a raw `Scaffold` is what keeps the header pattern
/// identical everywhere: same height, same back behaviour, same action budget.
class OScreen extends StatelessWidget {
  const OScreen({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.leading,
    this.actions = const <Widget>[],
    this.showBack,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.maxWidth,
    this.padding = true,
    this.resizeToAvoidBottomInset = true,
    this.headerBottom,
    this.backgroundColor,
    this.bodyAlignment = Alignment.topCenter,
  });

  final String title;

  /// Six words maximum. If it needs more, the screen is doing too much.
  final String? subtitle;
  final Widget child;
  final Widget? leading;
  final List<Widget> actions;

  /// Defaults to "pop when there is something to pop".
  final bool? showBack;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final double? maxWidth;
  final bool padding;
  final bool resizeToAvoidBottomInset;
  final PreferredSizeWidget? headerBottom;
  final Color? backgroundColor;
  final Alignment bodyAlignment;

  @override
  Widget build(BuildContext context) {
    final r = OResponsive.of(context);
    final canPop = Navigator.of(context).canPop();
    final visibleActions = actions.take(r.headerActionBudget).toList();
    return OScaffold(
      backgroundColor: backgroundColor,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      bottomNavigationBar: bottomNavigationBar,
      floatingActionButton: floatingActionButton,
      appBar: OAppBar(
        title: title,
        subtitle: subtitle,
        leading: leading,
        actions: visibleActions,
        bottom: headerBottom,
        showBack: showBack ?? canPop,
      ),
      body: OContent(
        maxWidth: maxWidth,
        padding: padding,
        alignment: bodyAlignment,
        child: child,
      ),
    );
  }
}

/// The four states every data screen has. One widget so they look the same.
enum OStatus { loading, empty, error, content }

class OStateView extends StatelessWidget {
  const OStateView({
    super.key,
    required this.status,
    required this.child,
    this.emptyTitle,
    this.emptyBody,
    this.emptyActionLabel,
    this.onEmptyAction,
    this.errorMessage,
    this.onRetry,
    this.skeletonRows = 4,
  });

  final OStatus status;
  final Widget child;
  final String? emptyTitle;
  final String? emptyBody;
  final String? emptyActionLabel;
  final VoidCallback? onEmptyAction;
  final String? errorMessage;
  final VoidCallback? onRetry;
  final int skeletonRows;

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      OStatus.loading => OSkeletonList(rows: skeletonRows),
      OStatus.empty => OEmptyState(
        icon: Icons.inbox_rounded,
        title: emptyTitle ?? 'Nothing here',
        message: emptyBody ?? '',
        action: emptyActionLabel == null || onEmptyAction == null
            ? null
            : OButton(
                label: emptyActionLabel!,
                onPressed: onEmptyAction,
                variant: OButtonVariant.secondary,
              ),
      ),
      OStatus.error => OErrorState(
        message: errorMessage ?? 'Something went wrong.',
        onRetry: onRetry,
      ),
      OStatus.content => child,
    };
  }
}

/// A calm section heading: three words, optional trailing action, no icon.
class OSectionTitle extends StatelessWidget {
  const OSectionTitle({
    super.key,
    required this.title,
    this.meta,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.only(top: OSpace.l, bottom: OSpace.s),
  });

  final String title;

  /// A count or status that belongs to the heading ("3 files", "Not reported").
  final String? meta;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      title.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.overline.copyWith(color: c.textMuted),
                    ),
                  ),
                  if (meta != null) ...[
                    const SizedBox(width: OSpace.s),
                    Flexible(
                      child: Text(
                        meta!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.caption.copyWith(color: c.textFaint),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (actionLabel != null && onAction != null)
            OTextAction(label: actionLabel!, onPressed: onAction!),
        ],
      ),
    );
  }
}

/// A section heading plus its body, with the standard gap below.
///
/// Settings pages had six private `_Section` copies of exactly this column;
/// the rhythm between a heading and its card belongs here, not in a screen.
class OSection extends StatelessWidget {
  const OSection({
    super.key,
    required this.title,
    required this.child,
    this.meta,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.only(bottom: OSpace.l),
  });

  final String title;
  final Widget child;
  final String? meta;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionTitle(
            title: title,
            meta: meta,
            actionLabel: actionLabel,
            onAction: onAction,
          ),
          child,
        ],
      ),
    );
  }
}

/// Small text-only action, used where a full button would add noise.
class OTextAction extends StatelessWidget {
  const OTextAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final enabled = onPressed != null;
    final color = enabled ? c.accent : c.textFaint;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: OPressable(
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: OSpace.touch),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: OSpace.s),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: OSpace.xs),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: OType.label.copyWith(color: color),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Wraps a body so a pushed page and a tab page share the same entrance.
class OFadeIn extends StatelessWidget {
  const OFadeIn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (OMove.reduced(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: OMotion.medium,
      curve: OMotion.standard,
      builder: (context, value, child) =>
          Opacity(opacity: value, child: child),
      child: child,
    );
  }
}
