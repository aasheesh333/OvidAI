import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'step_progress.dart';

// TODO(l10n): move onboarding copy to the ARB files.

@immutable
class V2LanguageOption {
  const V2LanguageOption({required this.id, required this.nativeLabel});

  final String id;

  /// The name a speaker recognises, written in the language itself
  /// (English, हिन्दी, தமிழ்).
  final String nativeLabel;
}

@immutable
class V2GoalOption {
  const V2GoalOption({
    required this.id,
    required this.title,
    required this.icon,
  });

  final String id;
  final String title;
  final IconData icon;
}

@immutable
class V2LanguageGoalData {
  const V2LanguageGoalData({
    this.languages = const [
      V2LanguageOption(id: 'en', nativeLabel: 'English'),
      V2LanguageOption(id: 'hi', nativeLabel: 'हिन्दी'),
      V2LanguageOption(id: 'hinglish', nativeLabel: 'Hinglish'),
      V2LanguageOption(id: 'pa', nativeLabel: 'ਪੰਜਾਬੀ'),
      V2LanguageOption(id: 'ta', nativeLabel: 'தமிழ்'),
    ],
    this.selectedLanguageId = 'en',
    this.goals = const [
      V2GoalOption(
        id: 'build',
        title: 'Build something',
        icon: Icons.code_rounded,
      ),
      V2GoalOption(
        id: 'research',
        title: 'Research',
        icon: Icons.search_rounded,
      ),
      V2GoalOption(id: 'write', title: 'Write', icon: Icons.edit_note_rounded),
      V2GoalOption(
        id: 'automate',
        title: 'Automate my work',
        icon: Icons.bolt_rounded,
      ),
      V2GoalOption(
        id: 'explore',
        title: 'Explore',
        icon: Icons.explore_rounded,
      ),
    ],
    this.selectedGoalIds = const {'build'},
    this.step = V2OnboardingTour.language,
    this.totalSteps = V2OnboardingTour.totalSteps,
    this.loading = false,
    this.error,
  });

  final List<V2LanguageOption> languages;
  final String? selectedLanguageId;
  final List<V2GoalOption> goals;
  final Set<String> selectedGoalIds;
  final int step;
  final int totalSteps;
  final bool loading;
  final String? error;
}

typedef V2LanguageGoalContinue =
    void Function(String languageId, Set<String> goalIds);

/// Second step of the tour: two quick choices, then the shared footer action.
class LanguageGoalPage extends StatefulWidget {
  const LanguageGoalPage({
    super.key,
    this.data = const V2LanguageGoalData(),
    this.onLanguageSelected,
    this.onGoalToggled,
    this.onContinue,
    this.onRetry,
    this.onClose,
    this.onBack,
  });

  final V2LanguageGoalData data;
  final ValueChanged<String>? onLanguageSelected;
  final void Function(String goalId, bool selected)? onGoalToggled;
  final V2LanguageGoalContinue? onContinue;
  final VoidCallback? onRetry;
  final VoidCallback? onClose;

  /// Returns to the step the language screen was opened from. Null hides the
  /// back arrow (a root tour step has nothing to pop).
  final VoidCallback? onBack;

  @override
  State<LanguageGoalPage> createState() => _LanguageGoalPageState();
}

class _LanguageGoalPageState extends State<LanguageGoalPage> {
  late String? _languageId = widget.data.selectedLanguageId;
  late Set<String> _goalIds = _visibleGoalIds(widget.data);

  @override
  void didUpdateWidget(covariant LanguageGoalPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data.selectedLanguageId != oldWidget.data.selectedLanguageId) {
      _languageId = widget.data.selectedLanguageId;
    }
    if (!_sameGoals(
      widget.data.selectedGoalIds,
      oldWidget.data.selectedGoalIds,
    )) {
      _goalIds = _visibleGoalIds(widget.data);
    }
  }

  void _selectLanguage(String id) {
    if (id == _languageId) return;
    setState(() => _languageId = id);
    widget.onLanguageSelected?.call(id);
  }

  void _toggleGoal(String id) {
    final selected = !_goalIds.contains(id);
    setState(() {
      if (selected) {
        _goalIds.add(id);
      } else {
        _goalIds.remove(id);
      }
    });
    widget.onGoalToggled?.call(id, selected);
  }

  void _continue() {
    final languageId = _languageId;
    if (languageId == null) return;
    if (widget.data.goals.isNotEmpty && _goalIds.isEmpty) return;
    widget.onContinue?.call(languageId, Set.unmodifiable(_goalIds));
  }

  /// A step is only valid when a language is chosen and, if goals are offered,
  /// at least one is selected. The footer action stays visible but disabled so
  /// the layout does not jump and the reason is announced.
  bool get _canContinue =>
      widget.onContinue != null &&
      _languageId != null &&
      (widget.data.goals.isEmpty || _goalIds.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final hasChoices =
        !data.loading && data.error == null && data.languages.isNotEmpty;
    final Widget body;
    if (data.loading) {
      body = const OSkeletonList(rows: 7);
    } else if (data.error != null) {
      body = OErrorState(
        title: 'Choices did not load',
        message: data.error!,
        onRetry: widget.onRetry,
      );
    } else if (data.languages.isEmpty) {
      body = OEmptyState(
        icon: Icons.language_rounded,
        title: 'No voice languages yet',
        message: 'Check your connection and try again.',
        action: widget.onRetry == null
            ? null
            : OButton(label: 'Try again', onPressed: widget.onRetry),
      );
    } else {
      body = _content(context, data);
    }

    final valid = _canContinue;
    return OnboardingStepScaffold(
      step: V2OnboardingStepData(
        step: data.step,
        totalSteps: data.totalSteps,
        trailingLabel: '',
      ),
      title: 'Voice & goal',
      onBack: widget.onBack,
      backKey: const Key('language-goal-back'),
      onClose: widget.onClose,
      primaryKey: const Key('language-goal-continue'),
      primaryLabel: 'Continue',
      onPrimary: valid ? _continue : null,
      primaryEnabled: valid,
      primaryVisible: hasChoices,
      scrollable: !data.loading,
      footerNote: valid || !hasChoices
          ? null
          : _languageId == null
          ? 'Choose a language to continue.'
          : 'Pick at least one goal to continue.',
      child: body,
    );
  }

  Widget _content(BuildContext context, V2LanguageGoalData data) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const OSectionTitle(
          title: 'Language',
          padding: EdgeInsets.only(bottom: OSpace.s),
        ),
        _ChipGrid(
          children: [
            for (final language in data.languages)
              OChip(
                label: language.nativeLabel,
                selected: language.id == _languageId,
                onTap: () => _selectLanguage(language.id),
              ),
          ],
        ),
        if (data.goals.isNotEmpty) ...[
          const OSectionTitle(
            title: 'Goal',
            padding: EdgeInsets.only(top: OSpace.xl, bottom: OSpace.s),
          ),
          _ChipGrid(
            children: [
              for (final goal in data.goals)
                OChip(
                  label: goal.title,
                  icon: goal.icon,
                  selected: _goalIds.contains(goal.id),
                  onTap: () => _toggleGoal(goal.id),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A grid of chips: one column under 360 dp, two from 360 dp, three from
/// 600 dp. Cells share the column width and the chip centres inside its cell,
/// so large text wraps to the next row instead of clipping a card.
class _ChipGrid extends StatelessWidget {
  const _ChipGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // The band comes from the window, not the (already capped) content width:
    // at exactly 600 dp the page is a tablet even though its column is
    // narrower. Below 360 dp a single column keeps 200 % text readable.
    final width = OResponsive.of(context).width;
    final columns = width < OBreakpoints.compact
        ? 1
        : width < OBreakpoints.tablet
        ? 2
        : 3;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      final end = i + columns < children.length ? i + columns : children.length;
      rows.add(
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : OSpace.s),
          child: Row(
            children: [
              for (var j = 0; j < columns; j++) ...[
                if (j > 0) const SizedBox(width: OSpace.s),
                Expanded(
                  child: j < end - i ? children[i + j] : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

/// Keeps only the selections that are actually on screen, so a stale id can
/// never travel out through `onContinue`.
Set<String> _visibleGoalIds(V2LanguageGoalData data) {
  final available = data.goals.map((goal) => goal.id).toSet();
  return {
    for (final id in data.selectedGoalIds)
      if (available.contains(id)) id,
  };
}

bool _sameGoals(Set<String> a, Set<String> b) {
  if (a.length != b.length) return false;
  for (final id in a) {
    if (!b.contains(id)) return false;
  }
  return true;
}
