// SettingsRepository over Supabase. Mirrors
// packages/suskii_data/lib/src/supabase/supabase_settings_repository.dart.
//
// Notification preferences live in `notification_preferences` (one row per
// channel × category); the flat entity is composed/exploded by
// notificationPreferencesFromRows / notificationPreferenceRows and written
// with an upsert on the (user_id, channel, category) key.
//
// Trusted contacts: the number goes in as plaintext over TLS and the server
// seals it (CR-20260923-06, contracts 2.0.0); the list reads it back masked.
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
const contactColumns = 'id, name, phone_masked, created_at';

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

  async addTrustedContact(options: {
    name: string;
    phoneE164: string;
    idempotencyKey: string;
  }): Promise<TrustedContact> {
    const id = await this.gateway.rpc('add_trusted_contact', {
      p_idempotency_key: options.idempotencyKey,
      p_name: options.name,
      p_phone_e164: options.phoneE164,
    });
    const row = await this.gateway.selectSingle(
      'trusted_contacts',
      contactColumns,
      'id',
      SupabaseGateway.asId(id),
    );
    if (row == null) throw new AppError(ErrorCodes.unknown);
    return trustedContactFromRow(row);
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

  /** Keeps an account scheduled for erasure; false when nothing was scheduled. */
  async cancelAccountDeletion(idempotencyKey: string): Promise<boolean> {
    const result = await this.gateway.rpc('cancel_account_deletion', {
      p_idempotency_key: idempotencyKey,
    });
    return result === true;
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
