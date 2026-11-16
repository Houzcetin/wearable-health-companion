import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../data/auth_repository.dart';
import '../../data/coach_repository.dart';
import '../../data/providers.dart';
import 'widgets/coach_consent_card.dart';
import 'widgets/message_bubble.dart';

const suggestedQuestions = [
  'Why did I sleep badly this week?',
  'How was my resting heart rate this month?',
  'Which days was I most active?',
];

class CoachScreen extends ConsumerStatefulWidget {
  const CoachScreen({super.key, this.initialQuestion, this.launchId});
  final String? initialQuestion;
  final Object? launchId;
  @override
  ConsumerState<CoachScreen> createState() => _CoachScreenState();
}

class _CoachScreenState extends ConsumerState<CoachScreen> {
  late final TextEditingController _input;
  final _scroll = ScrollController();
  bool _granting = false;
  String? _consentError;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: _prefill(widget.initialQuestion));
  }

  String _prefill(String? value) =>
      (value ?? '').characters.take(500).toString();

  @override
  void didUpdateWidget(covariant CoachScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialQuestion != null &&
        (oldWidget.initialQuestion != widget.initialQuestion ||
            oldWidget.launchId != widget.launchId)) {
      _input.text = _prefill(widget.initialQuestion);
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _allow() async {
    final user = ref.read(currentUserProvider);
    if (user == null || _granting) return;
    setState(() { _granting = true; _consentError = null; });
    try {
      await ref.read(profileRepositoryProvider).grantCoachConsent(user.id);
      if (!mounted) return;
      ref.invalidate(profileProvider);
      final profile = await ref.read(profileProvider.future);
      if (profile?.coachConsentAt == null) {
        throw const UserFacingException('Consent has not been saved yet. Please try again.');
      }
      if (mounted) ref.invalidate(coachThreadProvider);
    } catch (error) {
      if (mounted) {
        setState(() => _consentError = error is UserFacingException
            ? error.message : 'Could not save your consent. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _granting = false);
    }
  }

  void _send() {
    final question = _input.text.trim();
    if (question.isEmpty || question.length > 500 ||
        ref.read(coachThreadProvider).value?.sending == true) {
      return;
    }
    _input.clear();
    ref.read(coachThreadProvider.notifier).send(question);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider);
    final thread = ref.watch(coachThreadProvider);
    ref.listen(coachThreadProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('Coach'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.add, size: 18),
            onPressed: thread.isLoading || thread.value?.sending == true ||
                profile.value?.coachConsentAt == null
                ? null : () {
                  ref.read(coachThreadProvider.notifier).newChat();
                  _input.clear();
                  setState(() {});
                },
            label: const Text('New chat'),
          ),
          const SizedBox(width: AppSpace.s),
        ],
      ),
      body: !ref.watch(backendConfiguredProvider)
          ? const Center(child: Text('Backend not configured'))
          : profile.when(
              skipLoadingOnRefresh: false,
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => _loadError('Could not load your account.', () {
                ref.invalidate(profileProvider);
              }),
              data: (value) {
                if (value?.coachConsentAt == null ||
                    thread.value?.error?.code == 'consent_required') {
                  return SingleChildScrollView(
                    padding: AppSpace.page,
                    child: CoachConsentCard(
                      busy: _granting, error: _consentError, onAllow: _allow,
                      onNotNow: () => context.go('/today'),
                    ),
                  );
                }
                return thread.when(
                  skipLoadingOnRefresh: false,
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (error, _) => _loadError(mapCoachError(error).message,
                    () => ref.invalidate(coachThreadProvider)),
                  data: _chat,
                );
              },
            ),
    );
  }

  Widget _loadError(String message, VoidCallback retry) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpace.xxl),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: AppSpace.m),
        OutlinedButton(onPressed: retry, child: const Text('Retry')),
      ]),
    ),
  );

  Widget _chat(CoachThread thread) => SafeArea(
    child: Column(
      children: [
        Expanded(
          child: ListView(
            controller: _scroll, padding: AppSpace.page,
            children: [
              if (thread.messages.isEmpty) ...[
                const _CoachIntro(),
                const SizedBox(height: AppSpace.l),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final question in suggestedQuestions)
                    ActionChip(
                      label: Text(question),
                      onPressed: () => setState(() => _input.text = question),
                    ),
                ]),
              ],
              for (final message in thread.messages) MessageBubble(message: message),
              if (thread.sending)
                Semantics(
                  liveRegion: true, label: 'Coach is typing',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpace.s),
                    child: Row(children: [
                      const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: AppSpace.s),
                      Text('Thinking…', style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ]),
                  ),
                ),
              if (thread.error != null)
                Semantics(
                  liveRegion: true,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(thread.error!.message,
                        style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      if (thread.error!.code != 'daily_limit') ...[
                        const SizedBox(height: AppSpace.s),
                        OutlinedButton(
                          onPressed: thread.sending ? null :
                            () => ref.read(coachThreadProvider.notifier).retry(),
                          child: const Text('Retry'),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.l, AppSpace.s, AppSpace.l, AppSpace.xs),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(child: TextField(
              key: const Key('coach-input'),
              controller: _input,
              maxLength: 500, maxLines: 3, minLines: 1,
              inputFormatters: [LengthLimitingTextInputFormatter(500)],
              decoration: const InputDecoration(hintText: 'Ask the coach'),
              // The 500-character limit only matters near the end.
              buildCounter: (context, {required currentLength, required isFocused,
                  required maxLength}) => currentLength > 400
                  ? Text('$currentLength/$maxLength') : null,
              onChanged: (_) => setState(() {}),
              onSubmitted: thread.sending ? null : (_) => _send(),
            )),
            const SizedBox(width: AppSpace.s),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: IconButton.filled(
                key: const Key('coach-send'), tooltip: 'Send',
                onPressed: thread.sending || _input.text.trim().isEmpty ||
                    _input.text.trim().length > 500 ? null : _send,
                icon: const Icon(Icons.arrow_upward),
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.s),
          child: Text('Not medical advice.', style: Theme.of(context)
            .textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      ],
    ),
  );
}

class _CoachIntro extends StatelessWidget {
  const _CoachIntro();
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: AppSpace.s),
      Text('What would you like to know?', style: theme.textTheme.headlineSmall),
      const SizedBox(height: AppSpace.s),
      Text('Ask about your sleep, heart rate or activity.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant)),
    ]);
  }
}
