// SettingsRepository over Supabase. Mirrors
// packages/suskii_data/lib/src/supabase/supabase_settings_repository.dart.
//
// Notification preferences live in `notification_preferences` (one row per
// channel × category); the flat entity is composed/exploded by
// notificationPreferencesFromRows / notificationPreferenceRows and written
// with an upsert on the (user_id, channel, category) key.
//
// Trusted contacts: the contract stores phone numbers encrypted
// (`phone_ciphertext` + blind index) and offers no client key-management or
// server-side encrypt helper, so addTrustedContact is unavailable until
// CR-20260923-06 lands; reads map with an empty `phoneE164`.
//
// Account deletion and data export: request_account_deletion and
// request_data_export (CR-20260923-07, contracts 1.2.0).

import { AppError, ErrorCodes } from '@/mocks/errors';
import type {
  NotificationPreferences,
  TrustedContact,
} from '@/mocks/types';

import { SupabaseGateway } from './gateway';
import {
  notificationPreferenceRows,
  notificationPreferencesFromRows,
  trustedContactFromRow,
} from './mappers';

const prefColumns = 'channel, category, enabled, quiet_start, quiet_end';
const contactColumns = 'id, name, created_at';

export class SupabaseSettingsRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  async getNotificationPreferences(): Promise<NotificationPreferences> {
    const rows = await this.gateway.selectList(
      'notification_preferences',
      prefColumns,
    );
    return notificationPreferencesFromRows(rows);
  }

  async updateNotificationPreferences(
    preferences: NotificationPreferences,
    _idempotencyKey: string,
  ): Promise<NotificationPreferences> {
    const userId = await this.gateway.currentAuthUserId();
    if (userId === undefined) throw new AppError(ErrorCodes.unauthenticated);
    const rows = await this.gateway.upsertRows(
      'notification_preferences',
      notificationPreferenceRows(userId, preferences),
      'user_id,channel,category',
      prefColumns,
    );
    return notificationPreferencesFromRows(rows);
  }

  async getTrustedContacts(): Promise<TrustedContact[]> {
    const rows = await this.gateway.selectList(
      'trusted_contacts',
      contactColumns,
      { orderBy: 'created_at' },
    );
    return rows.map(trustedContactFromRow);
  }

  async addTrustedContact(_options: {
    name: string;
    phoneE164: string;
    idempotencyKey: string;
  }): Promise<TrustedContact> {
    // add_trusted_contact expects phone_ciphertext + blind index; the client
    // has no encryption story (CR-20260923-06) and sending plaintext as
    // "ciphertext" would weaken the security model.
    throw new AppError(ErrorCodes.featureUnavailable);
  }

  async removeTrustedContact(
    contactId: string,
    _idempotencyKey: string,
  ): Promise<void> {
    await this.gateway.rpc('remove_trusted_contact', {
      p_contact_id: contactId,
    });
  }

  /**
   * Schedules the account for erasure and returns the date. The server revokes
   * every session with the request, this one included; signing back in before
   * the date offers to keep the account.
   */
  async requestAccountDeletion(idempotencyKey: string): Promise<Date> {
    const result = await this.gateway.rpc('request_account_deletion', {
      p_idempotency_key: idempotencyKey,
    });
    if (typeof result !== 'string') throw new AppError(ErrorCodes.unknown);
    return new Date(result);
  }

  /** Queues an export of the caller's data and returns its reference. */
  async requestDataExport(idempotencyKey: string): Promise<string> {
    const result = await this.gateway.rpc('request_data_export', {
      p_idempotency_key: idempotencyKey,
    });
    if (typeof result !== 'string') throw new AppError(ErrorCodes.unknown);
    return result;
  }
}
