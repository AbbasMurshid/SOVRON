import { describe, expect, it } from "vitest";
import { buildSyncDelta, SyncConflictError } from "./cloud-store";

describe("atomic snapshot diffs", () => {
  it("sends only inserts and changed rows with expected versions, plus explicit versioned deletes", () => {
    const before = [
      { id: "unchanged", name: "Same", version: 4 },
      { id: "updated", name: "Before", version: 8 },
      { id: "deleted", name: "Remove", version: 3 },
    ];
    const after = [
      { id: "unchanged", name: "Same", version: 4 },
      { id: "updated", name: "After", version: 8 },
      { id: "inserted", name: "New" },
    ];

    const delta = buildSyncDelta(before, after, row => ({ id: row.id, user_id: "user-1", name: row.name }));

    expect(delta.writes).toEqual([
      { id: "updated", user_id: "user-1", name: "After", expected_version: 8 },
      { id: "inserted", user_id: "user-1", name: "New", expected_version: null },
    ]);
    expect(delta.deletes).toEqual([{ id: "deleted", version: 3 }]);
  });

  it("refuses updates and deletes when the client has no database version", () => {
    expect(() => buildSyncDelta([{ id: "a", name: "old" }], [{ id: "a", name: "new" }], row => ({ name: row.name }))).toThrow(SyncConflictError);
    expect(() => buildSyncDelta([{ id: "a", name: "old" }], [], row => ({ name: row.name }))).toThrow(SyncConflictError);
  });
});
