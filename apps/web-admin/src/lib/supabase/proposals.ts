// Proposals through the config-change four eyes. Referral campaigns, promo codes and
// staff access all change only when a second super admin signs (RLS matrix §6), so a
// "create" or "pause" in the console files a proposal and returns; Config → pending
// changes is where somebody else approves it.

import { SupabaseGateway, type Row } from './gateway';

export async function propose(
  gw: SupabaseGateway,
  idempotencyKey: string,
  target: string,
  targetKey: string,
  proposed: Record<string, unknown>,
  countryCode?: string,
  note?: string,
): Promise<string> {
  return String(
    await gw.rpc('propose_config_change', {
      p_idempotency_key: idempotencyKey,
      p_target: target,
      p_target_key: targetKey,
      p_proposed: proposed,
      p_country_code: countryCode,
      p_note: note,
    }),
  );
}

/** Pending proposals for a target, newest first. */
export async function pendingProposals(gw: SupabaseGateway, target: string): Promise<Row[]> {
  const rows = await gw.selectList(
    'config_changes',
    'id, target, target_key, country_code, proposed, status, requested_by, created_at',
    { column: 'target', value: target, orderBy: 'created_at', ascending: false, limit: 100 },
  );
  return rows.filter((r) => r['status'] === 'pending');
}
