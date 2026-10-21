import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'step_progress.dart';

// TODO(l10n): move onboarding copy to the ARB files.

@immutable
class V2LanguageOption {
  const V2LanguageOption({
    required this.id,
    required this.nativeLabel,
    required this.englishLabel,
    required this.scriptLabel,
    this.isDefault = false,
  });

  final String id;
  final String nativeLabel;
  final String englishLabel;
  final String scriptLabel;
  final bool isDefault;
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
      V2LanguageOption(
        id: 'en',
        nativeLabel: 'English',
        englishLabel: 'Global',
        scriptLabel: 'Latin',
        isDefault: true,
      ),
      V2LanguageOption(
        id: 'hi',
        nativeLabel: 'हिन्दी',
        englishLabel: 'Hindi',
        scriptLabel: 'Devanagari',
      ),
      V2LanguageOption(
        id: 'pa',
        nativeLabel: 'ਪੰਜਾਬੀ',
        englishLabel: 'Punjabi',
        scriptLabel: 'Gurmukhi',
      ),
      V2LanguageOption(
        id: 'ta',
        nativeLabel: 'தமிழ்',
        englishLabel: 'Tamil',
        scriptLabel: 'Tamil',
      ),
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
        title: 'Just explore',
        icon: Icons.explore_rounded,
      ),
    ],
    this.selectedGoalIds = const {'build'},
    this.step = 1,
    this.totalSteps = 3,
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

class LanguageGoalPage extends StatefulWidget {
  const LanguageGoalPage({
    super.key,
    this.data = const V2LanguageGoalData(),
    this.onLanguageSelected,
    this.onGoalToggled,
    this.onContinue,
    this.onRetry,
    this.onSeeAllLanguages,
    this.onClose,
  });

  final V2LanguageGoalData data;
  final ValueChanged<String>? onLanguageSelected;
  final void Function(String goalId, bool selected)? onGoalToggled;
  final V2LanguageGoalContinue? onContinue;
  final VoidCallback? onRetry;
  final VoidCallback? onSeeAllLanguages;
  final VoidCallback? onClose;

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
    widget.onContinue?.call(languageId, Set.unmodifiable(_goalIds));
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    final Widget body;
    if (data.loading) {
      body = const OSkeletonList(rows: 7);
    } else if (data.error != null) {
      body = OErrorState(
        title: 'We could not load your choices',
        message: data.error!,
        onRetry: widget.onRetry,
      );
    } else if (data.languages.isEmpty) {
      body = OEmptyState(
        icon: Icons.language_rounded,
        title: 'No languages yet',
        message: 'Check your connection and try again.',
        action: widget.onRetry == null
            ? null
            : OButton(label: 'Try again', onPressed: widget.onRetry),
      );
    } else {
      body = _content(context, c, data);
    }

    return OScaffold(
      appBar: OAppBar(
        title: 'Language & goal',
        actions: [
          if (widget.onClose != null)
            OIconButton(
              icon: Icons.close_rounded,
              semanticLabel: 'Close',
              onPressed: widget.onClose,
            ),
        ],
      ),
      body: body,
      bottomNavigationBar:
          !data.loading && data.error == null && data.languages.isNotEmpty
          ? _continueBar(c, data)
          : null,
    );
  }

  Widget _content(BuildContext context, OColors c, V2LanguageGoalData data) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xl,
      ),
      child: OFadeSlide(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OnboardingStepProgress(
              data: V2OnboardingStepData(
                step: data.step,
                totalSteps: data.totalSteps,
              ),
            ),
            const SizedBox(height: OSpace.l),
            _SetupBanner(c: c),
            const SizedBox(height: OSpace.xl),
            Text(
              'Which language do you think in?',
              style: OType.h2.copyWith(color: c.text),
            ),
            const SizedBox(height: OSpace.xs),
            Text(
              'Ovid speaks and codes fluently in 40+ languages.',
              style: OType.bodySm.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: OSpace.m),
            _LanguageGrid(
              languages: data.languages,
              selectedId: _languageId,
              onSelected: _selectLanguage,
            ),
            if (widget.onSeeAllLanguages != null) ...[
              const SizedBox(height: OSpace.s),
              OButton(
                label: 'See all 40+ languages',
                variant: OButtonVariant.ghost,
                icon: Icons.translate_rounded,
                onPressed: widget.onSeeAllLanguages,
              ),
            ],
            const SizedBox(height: OSpace.xl),
            Text(
              'What do you want Ovid to help with first?',
              style: OType.h2.copyWith(color: c.text),
            ),
            const SizedBox(height: OSpace.xs),
            Text(
              'You can change this anytime. Pick one or more.',
              style: OType.bodySm.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: OSpace.m),
            Wrap(
              spacing: OSpace.s,
              runSpacing: OSpace.s,
              children: [
                for (final goal in data.goals)
                  _GoalChip(
                    goal: goal,
                    selected: _goalIds.contains(goal.id),
                    onTap: () => _toggleGoal(goal.id),
                  ),
              ],
            ),
            if (data.goals.isEmpty) ...[
              const SizedBox(height: OSpace.m),
              Text(
                'No goals to pick yet. You can continue and change this later.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            ],
            const SizedBox(height: OSpace.xl),
          ],
        ),
      ),
    );
  }

  Widget _continueBar(OColors c, V2LanguageGoalData data) {
    final steps = data.totalSteps < 1 ? 1 : data.totalSteps;
    final active = data.step.clamp(1, steps);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(top: BorderSide(color: c.hairline)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            OSpace.screen,
            OSpace.m,
            OSpace.screen,
            OSpace.m,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              OButton(
                key: const Key('language-goal-continue'),
                label: 'Continue',
                icon: Icons.arrow_forward_rounded,
                expand: true,
                onPressed: _languageId == null ? null : _continue,
              ),
              const SizedBox(height: OSpace.s),
              Text(
                'Step $active of $steps · '
                'You can fine-tune this in settings.',
                textAlign: TextAlign.center,
                style: OType.caption.copyWith(color: c.textFaint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SetupBanner extends StatelessWidget {
  const _SetupBanner({required this.c});

  final OColors c;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        children: [
          Icon(Icons.auto_awesome_rounded, size: 20, color: c.accent),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Text(
              "We'll set things up in seconds.",
              style: OType.bodySm.copyWith(color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Two-column language grid. Each row is as tall as its tallest card, so large
/// text grows the card instead of clipping the native or script label.
class _LanguageGrid extends StatelessWidget {
  const _LanguageGrid({
    required this.languages,
    required this.selectedId,
    required this.onSelected,
  });

  final List<V2LanguageOption> languages;
  final String? selectedId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < languages.length; i += 2) {
      final second = i + 1 < languages.length ? languages[i + 1] : null;
      rows.add(
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : OSpace.s),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _card(languages[i])),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: second == null
                      ? const SizedBox.shrink()
                      : _card(second),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  Widget _card(V2LanguageOption language) => _LanguageCard(
    language: language,
    selected: language.id == selectedId,
    onTap: () => onSelected(language.id),
  );
}

class _LanguageCard extends StatelessWidget {
  const _LanguageCard({
    required this.language,
    required this.selected,
    required this.onTap,
  });

  final V2LanguageOption language;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return MergeSemantics(
      child: Semantics(
        label: '${language.nativeLabel}, ${language.englishLabel}',
        selected: selected,
        button: true,
        child: OPressable(
          onTap: onTap,
          child: ExcludeSemantics(
            child: AnimatedContainer(
              duration: OMotion.fast,
              curve: OMotion.standard,
              padding: const EdgeInsets.all(OSpace.m),
              decoration: BoxDecoration(
                color: selected ? c.accentSoft : c.surface,
                borderRadius: BorderRadius.circular(ORadius.l),
                border: Border.all(
                  color: selected
                      ? c.accentFill.withValues(alpha: 0.50)
                      : c.hairline,
                  width: selected ? 1.5 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          language.isDefault ? 'Default' : language.scriptLabel,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ),
                      Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: selected ? c.accentFill : Colors.transparent,
                          border: Border.all(
                            color: selected ? c.accentFill : c.hairlineStrong,
                          ),
                        ),
                        child: selected
                            ? Icon(
                                Icons.check_rounded,
                                size: 14,
                                color: c.onAccent,
                              )
                            : null,
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    language.nativeLabel,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: OType.h2.copyWith(color: c.text),
                  ),
                  Text(
                    language.englishLabel,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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

class _GoalChip extends StatelessWidget {
  const _GoalChip({
    required this.goal,
    required this.selected,
    required this.onTap,
  });

  final V2GoalOption goal;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return MergeSemantics(
      child: Semantics(
        label: goal.title,
        selected: selected,
        button: true,
        child: OPressable(
          onTap: onTap,
          child: ExcludeSemantics(
            child: AnimatedContainer(
              duration: OMotion.fast,
              curve: OMotion.standard,
              constraints: const BoxConstraints(minHeight: OSpace.touch),
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.l,
                vertical: OSpace.m,
              ),
              decoration: BoxDecoration(
                color: selected ? c.accentSoft : c.surface,
                borderRadius: BorderRadius.circular(ORadius.m),
                border: Border.all(
                  color: selected
                      ? c.accentFill.withValues(alpha: 0.50)
                      : c.hairline,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    goal.icon,
                    size: 18,
                    color: selected ? c.accent : c.textMuted,
                  ),
                  const SizedBox(width: OSpace.s),
                  Flexible(
                    child: Text(
                      goal.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: OType.label.copyWith(
                        color: selected ? c.accent : c.text,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (selected) ...[
                    const SizedBox(width: OSpace.s),
                    Icon(Icons.check_rounded, size: 16, color: c.accent),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
