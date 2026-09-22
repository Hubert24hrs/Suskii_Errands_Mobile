// Compatibility shim — the seeded in-memory database and behavior switches
// live in ./fixtures and ./behavior. Import from there (or from
// ./repositories) directly; this module only re-exports.

export { db, createMockDatabase, MockDatabase } from './fixtures';
export { mockBehavior } from './behavior';
export type { Money } from './types';
