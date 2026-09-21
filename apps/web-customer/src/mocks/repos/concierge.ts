// AI concierge (text) + customer facial verification (customer scope).
//
// Concierge rules (mirrors MockConciergeRepository, hardened):
// - Deterministic slot filling: turn 1 classifies the category and takes the
//   text as the description; turn 2 fills the pickup. Money is NEVER a
//   concierge slot — the user sets the price on the publish card / form.
// - The concierge holds no publish/accept/pay capability. When the draft is
//   complete it proposes `show_publish_card` (or `handoff_to_form` for
//   custom categories); publishing goes through RequestRepository.
// - The underlying draft JobRequest is created from the first saved slot and
//   kept in sync, so half-finished drafts are resumable.

import { sleep } from '../behavior';
import { AppError, ErrorCodes } from '../errors';
import type { MockDatabase } from '../fixtures';
import type { MockBehavior } from '../behavior';
import type {
  ConciergeConversation,
  ConciergeDraft,
  ConciergeMessage,
  ConciergeProposedAction,
  JobRequest,
  LivenessResult,
  LivenessSession,
  VerificationSession,
} from '../types';
import { MockRepo, type Unsubscribe } from './base';
import { MockRequestRepository } from './requests';

const ALL_SLOTS = ['category', 'description', 'pickup'] as const;

const KEYWORDS: ReadonlyArray<readonly [string, string]> = [
  ['clean', 'cleaning_laundry'],
  ['laundry', 'cleaning_laundry'],
  ['move', 'moving'],
  ['food', 'food_pickup'],
  ['order', 'food_pickup'],
  ['deliver', 'errands_delivery'],
  ['parcel', 'errands_delivery'],
  ['package', 'errands_delivery'],
  ['buy', 'shopping'],
  ['shop', 'shopping'],
  ['groceries', 'shopping'],
  ['document', 'document_delivery'],
];

const SOS_KEYWORDS = ['sos', 'emergency', 'unsafe', 'danger', 'help me'];
const OFFER_KEYWORDS = ['offer', 'compare', 'price'];

function classify(text: string): { categoryId: string; isCustom: boolean } {
  const lower = text.toLowerCase();
  for (const [keyword, categoryId] of KEYWORDS) {
    if (lower.includes(keyword)) return { categoryId, isCustom: false };
  }
  return { categoryId: 'custom', isCustom: true };
}

interface ConversationState {
  messages: ConciergeMessage[];
  draft: ConciergeDraft;
  turn: number;
}

export class MockConciergeRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  private readonly conversations = new Map<string, ConversationState>();
  private readonly messageEvents = new Map<string, Set<(m: ConciergeMessage[]) => void>>();

  private static readonly EMPTY_DRAFT: ConciergeDraft = {
    isCustomCategory: false,
    missingSlots: [...ALL_SLOTS],
  };

  async startConversation(idempotencyKey: string): Promise<ConciergeConversation> {
    await this.gate();
    return this.idempotent('startConversation', idempotencyKey, '', () => {
      const conversation: ConciergeConversation = {
        id: `conv-${Date.now()}`,
        createdAt: this.now(),
        language: this.currentUser.preferredLanguage,
      };
      this.conversations.set(conversation.id, {
        messages: [
          {
            id: `cmsg-${conversation.id}-0`,
            conversationId: conversation.id,
            role: 'assistant',
            text: 'Welcome! Tell me what you need done, in your own words.',
            createdAt: this.now(),
            structuredDraft: MockConciergeRepository.EMPTY_DRAFT,
            proposedAction: 'none',
          },
        ],
        draft: { ...MockConciergeRepository.EMPTY_DRAFT },
        turn: 0,
      });
      return conversation;
    });
  }

  /** Emits the full message list immediately, then on every change. */
  watchMessages(
    conversationId: string,
    onChange: (messages: ConciergeMessage[]) => void,
  ): Unsubscribe {
    onChange([...(this.conversations.get(conversationId)?.messages ?? [])]);
    const listeners = (this.messageEvents.get(conversationId) ??
      (() => {
        const set = new Set<(m: ConciergeMessage[]) => void>();
        this.messageEvents.set(conversationId, set);
        return set;
      })());
    listeners.add(onChange);
    return () => {
      listeners.delete(onChange);
    };
  }

  private emit(conversationId: string): void {
    const messages = [...(this.conversations.get(conversationId)?.messages ?? [])];
    for (const listener of this.messageEvents.get(conversationId) ?? []) {
      listener(messages);
    }
  }

  /**
   * Streams assistant reply chunks (word by word). The complete message —
   * including any updated draft — is then observable via watchMessages.
   * Replaying the same idempotency key re-streams the stored reply without
   * re-running slot filling; the same key with a DIFFERENT text is refused.
   */
  async *sendMessage(
    conversationId: string,
    text: string,
    idempotencyKey: string,
  ): AsyncGenerator<string> {
    await this.gate();
    const state = this.conversations.get(conversationId);
    if (!state) throw new AppError(ErrorCodes.unknown);

    const cached = await this.idempotent(
      'conciergeSend',
      idempotencyKey,
      text,
      async () => this.runTurn(conversationId, state, text),
    );
    for (const word of cached.reply.split(' ')) {
      await sleep(40);
      yield `${word} `;
    }
  }

  private runTurn(
    conversationId: string,
    state: ConversationState,
    text: string,
  ): { reply: string } {
    state.turn += 1;
    const turn = state.turn;
    state.messages.push({
      id: `cmsg-${conversationId}-u${turn}`,
      conversationId,
      role: 'user',
      text,
      createdAt: this.now(),
      proposedAction: 'none',
    });

    const lower = text.toLowerCase();
    let draft = state.draft;
    let reply: string;
    let proposedAction: ConciergeProposedAction = 'none';

    if (SOS_KEYWORDS.some((k) => lower.includes(k))) {
      reply =
        'Your safety comes first. Open the SOS card to alert our team and ' +
        'your trusted contacts.';
      proposedAction = 'show_sos_card';
    } else if (
      draft.requestId !== undefined &&
      OFFER_KEYWORDS.some((k) => lower.includes(k)) &&
      draft.missingSlots.length === 0
    ) {
      reply = 'Here is how your offers compare — you decide which to accept.';
      proposedAction = 'show_offer_comparison';
    } else if (turn === 1) {
      const { categoryId, isCustom } = classify(text);
      draft = {
        ...draft,
        categoryId,
        isCustomCategory: isCustom,
        description: text,
        missingSlots: ['pickup'],
      };
      reply =
        'Got it. Where should this happen — what is the pickup or service ' +
        'location?';
    } else if (turn === 2) {
      draft = {
        ...draft,
        pickup: { label: text },
        missingSlots: [],
      };
      reply = draft.isCustomCategory
        ? 'Noted. This one needs the full form — I have prefilled what I can. ' +
          'You will set your offer price there yourself.'
        : 'Noted. Review the summary, set your offer price on the card, and ' +
          'confirm to publish your request.';
      proposedAction = draft.isCustomCategory
        ? 'handoff_to_form'
        : 'show_publish_card';
    } else if (/\d/.test(text) && draft.missingSlots.length === 0) {
      // Money is never auto-filled: acknowledge a spoken price, but the
      // exact amount is set by the user on the review card.
      reply =
        'I heard a price — for your protection the exact amount is set by ' +
        'you on the review card, not by me.';
      proposedAction = draft.isCustomCategory
        ? 'handoff_to_form'
        : 'show_publish_card';
    } else {
      reply =
        draft.requestId !== undefined
          ? 'Your request is ready — confirm to publish it.'
          : 'Anything else you want to add?';
      proposedAction =
        draft.requestId !== undefined && draft.missingSlots.length === 0
          ? draft.isCustomCategory
            ? 'handoff_to_form'
            : 'show_publish_card'
          : 'none';
    }

    // Server-side draft: the underlying draft JobRequest is created as soon
    // as the first slot is saved (resumable) and kept in sync. Money fields
    // are deliberately never synced from conversation.
    if (draft.requestId === undefined && draft.categoryId !== undefined) {
      const requests = new MockRequestRepository(this.db, this.behavior);
      return this.finishTurn(conversationId, state, draft, reply, proposedAction, () =>
        requests.createRequest(
          {
            categoryId: draft.categoryId ?? 'custom',
            isCustomCategory: draft.isCustomCategory,
            description: draft.description ?? '',
            pickup: draft.pickup ?? { label: '' },
            destination: draft.destination,
            urgency: draft.urgency ?? 'standard',
            scheduledAt: draft.scheduledAt,
          },
          `concierge-draft-${conversationId}`,
        ),
      );
    }
    this.syncDraftRequest(draft);
    return this.finishTurn(conversationId, state, draft, reply, proposedAction);
  }

  private finishTurn(
    conversationId: string,
    state: ConversationState,
    draft: ConciergeDraft,
    reply: string,
    proposedAction: ConciergeProposedAction,
    createDraft?: () => Promise<JobRequest>,
  ): { reply: string } {
    let finalDraft = draft;
    if (createDraft) {
      // The concierge is a streaming path; draft creation is idempotent per
      // conversation, so a replay never double-creates.
      void createDraft().then((created) => {
        const current = this.conversations.get(conversationId);
        if (!current) return;
        const withId: ConciergeDraft = { ...current.draft, requestId: created.id };
        current.draft = withId;
        const last = current.messages[current.messages.length - 1];
        if (last && last.role === 'assistant') {
          current.messages[current.messages.length - 1] = {
            ...last,
            structuredDraft: withId,
          };
        }
        this.emit(conversationId);
      });
    }
    state.draft = finalDraft;
    state.messages.push({
      id: `cmsg-${conversationId}-a${state.turn}`,
      conversationId,
      role: 'assistant',
      text: reply,
      createdAt: this.now(),
      structuredDraft: finalDraft,
      proposedAction,
    });
    this.emit(conversationId);
    return { reply };
  }

  private syncDraftRequest(draft: ConciergeDraft): void {
    if (draft.requestId === undefined) return;
    const stored = this.db.requests[draft.requestId];
    if (!stored) return;
    const updated: JobRequest = {
      ...stored,
      description: draft.description ?? stored.description,
      pickup: draft.pickup ?? stored.pickup,
      destination: draft.destination,
      urgency: draft.urgency ?? stored.urgency,
      scheduledAt: draft.scheduledAt,
    };
    this.db.requests[draft.requestId] = updated;
    this.db.jobEvents.emit(updated);
  }
}

/**
 * Customer facial-verification flow (consent → liveness + ID lookup →
 * result). All outcomes are decided here ("server-side"); the client only
 * requests them. `mockBehavior.failLiveness` forces the failure path.
 */
export class MockVerificationRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  private reviewTimer: ReturnType<typeof setTimeout> | undefined;

  async getCustomerVerification(): Promise<VerificationSession | undefined> {
    await this.gate();
    return this.db.verificationSessions[this.behavior.currentUserId];
  }

  /** Emits the current session (or undefined) immediately, then changes. */
  watchCustomerVerification(
    onChange: (session: VerificationSession | undefined) => void,
  ): Unsubscribe {
    onChange(this.db.verificationSessions[this.behavior.currentUserId]);
    return this.db.verificationEvents.subscribe(onChange);
  }

  private setSession(session: VerificationSession): void {
    this.db.verificationSessions[this.behavior.currentUserId] = session;
    this.db.verificationEvents.emit(session);
  }

  /** Records explicit consent for biometric processing. */
  async giveBiometricConsent(idempotencyKey: string): Promise<VerificationSession> {
    await this.gate();
    return this.idempotent('giveBiometricConsent', idempotencyKey, '', () => {
      const now = this.now();
      const session: VerificationSession = {
        id: `vs-${this.behavior.currentUserId}`,
        kind: 'customer_facial',
        status: 'in_progress',
        updatedAt: now,
        expiresAt: new Date(now.getTime() + 30 * 60_000),
      };
      this.setSession(session);
      return session;
    });
  }

  /** Throws ERR_CONSENT_REQUIRED when consent was not given. */
  async startFacialVerification(idempotencyKey: string): Promise<VerificationSession> {
    await this.gate();
    return this.idempotent('startFacialVerification', idempotencyKey, '', () => {
      const session = this.db.verificationSessions[this.behavior.currentUserId];
      if (!session || session.status === 'consent_pending') {
        throw new AppError(ErrorCodes.consentRequired);
      }
      if (session.status === 'verified') return session;
      const updated: VerificationSession = {
        ...session,
        status: 'in_progress',
        updatedAt: this.now(),
      };
      this.setSession(updated);
      return updated;
    });
  }

  /** On-device liveness capture stand-in (Smile ID SDK plugs in later). */
  async startLivenessSession(): Promise<LivenessSession> {
    await this.gate();
    return {
      sessionId: `liveness-${Date.now()}`,
      expiresAt: new Date(this.now().getTime() + 10 * 60_000),
    };
  }

  async captureLiveness(sessionId: string): Promise<LivenessResult> {
    await this.gate();
    if (this.behavior.failLiveness) {
      return { outcome: 'failed', reasonKey: 'livenessCheckFailed' };
    }
    return { outcome: 'success' };
  }

  /**
   * Moves the session to in-review and flips it to verified after
   * `kycReviewDelayMs` so the UI can demo the in-review → verified
   * transition.
   */
  async submitIdLookup(
    sessionId: string,
    idType: string,
    idNumber: string,
    idempotencyKey: string,
  ): Promise<VerificationSession> {
    await this.gate();
    return this.idempotent(
      `submitIdLookup:${sessionId}`,
      idempotencyKey,
      `${idType}|${idNumber}`,
      () => {
        const session = this.db.verificationSessions[this.behavior.currentUserId];
        if (!session || session.id !== sessionId || session.status !== 'in_progress') {
          throw new AppError(ErrorCodes.kycStepInvalid);
        }
        const inReview: VerificationSession = {
          ...session,
          status: 'in_review',
          updatedAt: this.now(),
        };
        this.setSession(inReview);
        if (this.reviewTimer !== undefined) clearTimeout(this.reviewTimer);
        this.reviewTimer = setTimeout(() => {
          const verified: VerificationSession = {
            ...inReview,
            status: 'verified',
            updatedAt: this.now(),
          };
          this.setSession(verified);
          const user = this.db.users[this.behavior.currentUserId];
          if (user) {
            this.db.users[user.id] = { ...user, customerVerification: 'verified' };
          }
        }, this.behavior.kycReviewDelayMs);
        return inReview;
      },
    );
  }
}
