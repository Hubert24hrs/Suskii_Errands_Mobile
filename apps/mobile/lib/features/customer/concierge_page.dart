import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/labels.dart';
import '../../app/providers.dart';
import '../../app/router.dart';

final _messagesProvider = StreamProvider.family<List<ConciergeMessage>, String>(
  (ref, conversationId) =>
      ref.watch(conciergeRepositoryProvider).watchMessages(conversationId),
);

/// AI concierge (text). The assistant only structures the request and
/// proposes actions — it never publishes, accepts or pays (A.1). Cards it
/// proposes are rendered by the UI and acted on with the app's own
/// idempotency keys. "Use the form instead" is always available (A.3).
class ConciergePage extends ConsumerStatefulWidget {
  const ConciergePage({super.key});

  @override
  ConsumerState<ConciergePage> createState() => _ConciergePageState();
}

class _ConciergePageState extends ConsumerState<ConciergePage> {
  final _composer = TextEditingController();
  String? _conversationId;
  String? _startKey;
  Object? _startError;
  bool _sending = false;
  String _streaming = '';
  bool _publishing = false;
  String? _publishKey;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _startError = null);
    try {
      // One key for the whole conversation intent; a retry after a network
      // failure replays the same conversation instead of opening a new one.
      _startKey ??= newIdempotencyKey();
      final conversation = await ref
          .read(conciergeRepositoryProvider)
          .startConversation(idempotencyKey: _startKey!);
      if (mounted) setState(() => _conversationId = conversation.id);
    } on Object catch (error) {
      if (mounted) setState(() => _startError = error);
    }
  }

  Future<void> _send() async {
    final id = _conversationId;
    final text = _composer.text.trim();
    if (id == null || text.isEmpty || _sending) return;
    _composer.clear();
    setState(() {
      _sending = true;
      _streaming = '';
    });
    try {
      // A fresh key per message intent (a tap), held until the turn ends.
      final key = newIdempotencyKey();
      await for (final String chunk
          in ref
              .read(conciergeRepositoryProvider)
              .sendMessage(id, text, idempotencyKey: key)) {
        if (mounted) setState(() => _streaming += chunk);
      }
    } on Object catch (error) {
      if (mounted) {
        showSToast(
          context,
          localizedError(AppLocalizations.of(context), error),
          isError: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _streaming = '';
        });
      }
    }
  }

  Future<void> _publish(ConciergeDraft draft) async {
    final requestId = draft.requestId;
    if (requestId == null || _publishing) return;
    setState(() => _publishing = true);
    try {
      _publishKey ??= newIdempotencyKey();
      final published = await ref
          .read(requestRepositoryProvider)
          .publishRequest(requestId, idempotencyKey: _publishKey!);
      if (mounted) {
        showSToast(context, AppLocalizations.of(context).createPublishedToast);
        unawaited(
          context.push(AppRoutes.customerRequestDetailPath(published.id)),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        showSToast(context, localizedError(l10n, error), isError: true);
        if (error is AppError &&
            error.code == ErrorCodes.verificationRequired) {
          unawaited(context.push(AppRoutes.verifyCustomer));
        }
      }
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  void _handoffToForm(ConciergeDraft? draft) {
    final params = <String, String>{
      if (draft?.categoryId != null) 'categoryId': draft!.categoryId!,
      if (draft?.description != null) 'description': draft!.description!,
      if (draft?.pickup != null) 'pickup': draft!.pickup!.label,
      if (draft?.preferredPrice != null)
        'priceMinor': draft!.preferredPrice!.minorUnits.toString(),
      if (draft?.preferredPrice != null)
        'currency': draft!.preferredPrice!.currencyCode,
    };
    unawaited(
      context.push(
        Uri(
          path: AppRoutes.customerRequestsNew,
          queryParameters: params,
        ).toString(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final id = _conversationId;
    final boot = ref.watch(bootstrapProvider).value;
    final voiceEnabled =
        boot?.voiceLanguages[Localizations.localeOf(context).languageCode] ==
        true;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.conciergeTitle),
        actions: <Widget>[
          if (voiceEnabled && id != null)
            IconButton(
              icon: const Icon(Icons.mic_outlined),
              tooltip: l10n.conciergeVoice,
              onPressed: () => unawaited(
                context.push(
                  '${AppRoutes.customerConciergeVoice}?conversationId=$id',
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: id == null
            ? _startError != null
                  ? SErrorState(
                      title: l10n.stateErrorGeneric,
                      message: localizedError(l10n, _startError!),
                      retryLabel: l10n.actionRetry,
                      onRetry: _start,
                    )
                  : const Center(child: CircularProgressIndicator())
            : _buildConversation(l10n, id),
      ),
    );
  }

  Widget _buildConversation(AppLocalizations l10n, String id) {
    final messages = ref.watch(_messagesProvider(id));
    final emergencyNumbers =
        ref.watch(bootstrapProvider).value?.countryPack.emergencyNumbers ??
        const <EmergencyNumber>[];
    return Column(
      children: <Widget>[
        Expanded(
          child: messages.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(SSpacing.lg),
              child: SSkeletonListTile(),
            ),
            error: (Object error, _) => SErrorState(
              title: l10n.stateErrorGeneric,
              message: localizedError(l10n, error),
              retryLabel: l10n.actionRetry,
              onRetry: () => ref.invalidate(_messagesProvider(id)),
            ),
            data: (List<ConciergeMessage> data) {
              final draft = _latestDraft(data);
              final action = data.isEmpty
                  ? ConciergeProposedAction.none
                  : data.last.proposedAction;
              return ListView(
                padding: const EdgeInsets.all(SSpacing.lg),
                children: <Widget>[
                  for (final ConciergeMessage m in data) _Bubble(message: m),
                  if (_sending || _streaming.isNotEmpty)
                    _Bubble(text: _streaming, streaming: true),
                  if (draft != null && draft.categoryId != null)
                    _DraftSummaryCard(draft: draft),
                  if (action == ConciergeProposedAction.showPublishCard &&
                      draft?.requestId != null)
                    _PublishCard(
                      publishing: _publishing,
                      onPublish: () => unawaited(_publish(draft!)),
                      onUseForm: () => _handoffToForm(draft),
                    ),
                  if (action == ConciergeProposedAction.showSosCard)
                    _SosCard(numbers: emergencyNumbers),
                  if (action == ConciergeProposedAction.showOfferComparison &&
                      draft?.requestId != null)
                    Padding(
                      padding: const EdgeInsets.only(top: SSpacing.sm),
                      child: SButton(
                        label: l10n.conciergeViewOffers,
                        variant: SButtonVariant.secondary,
                        onPressed: () => unawaited(
                          context.push(
                            AppRoutes.customerRequestDetailPath(
                              draft!.requestId!,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SSpacing.lg,
            SSpacing.sm,
            SSpacing.lg,
            SSpacing.sm,
          ),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      enabled: !_sending,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => unawaited(_send()),
                      decoration: InputDecoration(hintText: l10n.conciergeHint),
                    ),
                  ),
                  const SizedBox(width: SSpacing.sm),
                  IconButton(
                    icon: const Icon(Icons.send),
                    tooltip: l10n.conciergeSend,
                    onPressed: _sending ? null : () => unawaited(_send()),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _handoffToForm(
                    _latestDraft(messages.value ?? const <ConciergeMessage>[]),
                  ),
                  child: Text(l10n.conciergeUseForm),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  ConciergeDraft? _latestDraft(List<ConciergeMessage> messages) {
    for (final m in messages.reversed) {
      if (m.structuredDraft != null) return m.structuredDraft;
    }
    return null;
  }
}

class _Bubble extends StatelessWidget {
  _Bubble({ConciergeMessage? message, this.text, this.streaming = false})
    : isUser = message?.role == ConciergeRole.user,
      _message = message;

  final ConciergeMessage? _message;
  final String? text;
  final bool isUser;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = text ?? _message?.text ?? '';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: SSpacing.sm),
        padding: const EdgeInsets.all(SSpacing.md),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: SRadius.borderMd,
        ),
        child: Text(
          body.isEmpty && streaming ? '…' : body,
          style: theme.textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _DraftSummaryCard extends ConsumerWidget {
  const _DraftSummaryCard({required this.draft});

  final ConciergeDraft draft;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cats = ref.watch(categoriesProvider).value ?? const [];
    var category = l10n.catCustom;
    for (final c in cats) {
      if (c.id == draft.categoryId) category = categoryLabel(l10n, c.labelKey);
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(SSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(l10n.conciergeDraftTitle, style: theme.textTheme.titleSmall),
            const SizedBox(height: SSpacing.xs),
            Text(category, style: theme.textTheme.bodyMedium),
            if (draft.description != null)
              Text(draft.description!, style: theme.textTheme.bodySmall),
            if (draft.pickup != null && draft.pickup!.label.isNotEmpty)
              Text(
                '${l10n.detailPickupLabel}: ${draft.pickup!.label}',
                style: theme.textTheme.bodySmall,
              ),
            if (draft.preferredPrice != null)
              Text(
                '${l10n.detailPriceLabel}: ${draft.preferredPrice!.format()}',
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}

class _PublishCard extends StatelessWidget {
  const _PublishCard({
    required this.publishing,
    required this.onPublish,
    required this.onUseForm,
  });

  final bool publishing;
  final VoidCallback onPublish;
  final VoidCallback onUseForm;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(SSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              l10n.conciergePublishCardTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: SSpacing.xs),
            Text(l10n.conciergePublishCardBody),
            const SizedBox(height: SSpacing.sm),
            SButton(
              label: l10n.conciergePublish,
              loading: publishing,
              onPressed: publishing ? null : onPublish,
            ),
            TextButton(
              onPressed: onUseForm,
              child: Text(l10n.conciergeUseForm),
            ),
          ],
        ),
      ),
    );
  }
}

/// SOS card (A.4): emergency numbers on screen first, errand flow paused.
class _SosCard extends StatelessWidget {
  const _SosCard({required this.numbers});

  final List<EmergencyNumber> numbers;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(SSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              l10n.conciergeSosTitle,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: SSpacing.xs),
            Text(l10n.conciergeSosBody),
            const SizedBox(height: SSpacing.sm),
            for (final EmergencyNumber n in numbers)
              ListTile(
                dense: true,
                leading: const Icon(Icons.emergency_outlined),
                title: Text(emergencyNumberLabel(l10n, n.labelKey)),
                subtitle: Text(n.number),
                trailing: Text(l10n.conciergeSosCall(n.number)),
              ),
          ],
        ),
      ),
    );
  }
}
