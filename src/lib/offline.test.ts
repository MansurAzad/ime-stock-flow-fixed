import { beforeEach, describe, expect, it, vi } from "vitest";
import { enqueueOp, getQueue, isNetworkFailure, removeQueueEntry, replayQueue } from "./offline";
const { rpc, insert } = vi.hoisted(() => ({ rpc: vi.fn(), insert: vi.fn() }));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { from: () => ({ insert }), rpc } }));

const pay = (amount: number) => ({
  kind: "retailer_payment" as const,
  payload: { _retailer: "r1", _amount: amount, _method: "cash", _note: null, _date: null },
});

describe("offline queue", () => {
  beforeEach(() => {
    window.localStorage.clear();
    rpc.mockReset();
    insert.mockReset();
    rpc.mockResolvedValue({ data: null, error: null });
    insert.mockResolvedValue({ error: null });
  });

  it("stores entries in order with timestamps and unique uuid ids", () => {
    enqueueOp({ kind: "deposit", payload: { _salesman: "s1", _amount: 500, _method: "cash", _note: null, _date: null } });
    enqueueOp(pay(200));
    const q = getQueue();
    expect(q).toHaveLength(2);
    expect(q[0]?.op.kind).toBe("deposit");
    expect(q[1]?.op.kind).toBe("retailer_payment");
    expect(q[0]?.createdAt).toBeTruthy();
    expect(q[0]?.id).not.toBe(q[1]?.id);
    expect(q[0]?.id).toMatch(/^[0-9a-f-]{36}$/i);
  });

  it("survives a reload (reads back from local storage)", () => {
    enqueueOp({ kind: "add_retailer", payload: { name: "Test", phone: "", address: "", salesman_id: "s1" } });
    const raw = window.localStorage.getItem("offline-queue-v1");
    expect(raw).toBeTruthy();
    if (!raw) throw new Error("Queue was not saved");
    const parsed = JSON.parse(raw);
    expect(parsed[0].op.payload.name).toBe("Test");
  });

  it("detects network failures, not server rejections", () => {
    expect(isNetworkFailure(new Error("Failed to fetch"), false)).toBe(true);
    expect(isNetworkFailure({ message: "Network request failed" }, false)).toBe(true);
    expect(isNetworkFailure({ message: "insufficient stock" }, false)).toBe(false);
    expect(isNetworkFailure({ message: "admin only" }, false)).toBe(false);
    expect(isNetworkFailure({ message: "admin only" }, true)).toBe(true);
  });

  it("manual sync and reconnect share one replay and retain entries queued during replay", async () => {
    let finish: ((value: { data: null; error: null }) => void) | undefined;
    rpc.mockImplementation(() => new Promise((resolve) => { finish = resolve; }));
    enqueueOp(pay(500));
    const first = replayQueue();
    const second = replayQueue();
    expect(first).toBe(second);
    enqueueOp(pay(200));
    if (!finish) throw new Error("Replay did not start");
    finish({ data: null, error: null });
    await first;
    expect(rpc).toHaveBeenCalledTimes(1);
    expect(getQueue()).toHaveLength(1);
    expect(getQueue()[0]?.op.payload).toEqual(pay(200).payload);
  });

  it("a rejected entry stays with its error and does not block later entries", async () => {
    rpc
      .mockResolvedValueOnce({ data: null, error: { message: "IMEI not with you" } })
      .mockResolvedValue({ data: null, error: null });
    enqueueOp(pay(100));
    enqueueOp(pay(200));
    const result = await replayQueue();
    expect(result).toEqual({ synced: 1, failed: 1, firstError: "IMEI not with you" });
    const q = getQueue();
    expect(q).toHaveLength(1);
    expect(q[0]?.lastError).toBe("IMEI not with you");
    expect(q[0]?.attempts).toBe(1);
  });

  it("replays only the current user's entries and supports single-entry removal", async () => {
    enqueueOp(pay(100), "user-a");
    enqueueOp(pay(200), "user-b");
    const result = await replayQueue("user-a");
    expect(result.synced).toBe(1);
    expect(getQueue()).toHaveLength(1);
    removeQueueEntry(getQueue()[0]!.id);
    expect(getQueue()).toHaveLength(0);
  });

  it("sends the entry id as the idempotency key (_op)", async () => {
    const entry = enqueueOp(pay(100), "user-a");
    await replayQueue("user-a");
    expect(rpc).toHaveBeenCalledWith("record_retailer_payment", expect.objectContaining({ _op: entry.id }));
  });
});

describe("offline queue legacy upgrade", () => {
  beforeEach(() => { window.localStorage.clear(); rpc.mockReset(); rpc.mockResolvedValue({ data: null, error: null }); });

  it("assigns stable uuids to v1 entries and persists them", () => {
    window.localStorage.setItem("offline-queue-v1", JSON.stringify([
      { id: "1730000000000-0", createdAt: "2026-11-02T00:00:00Z", op: { kind: "deposit", payload: { salesman_id: "s1", amount: 700, note: null } } },
    ]));
    const first = getQueue();
    const second = getQueue();
    expect(first[0]?.id).toMatch(/^[0-9a-f-]{36}$/i);
    expect(second[0]?.id).toBe(first[0]?.id);
    const stored = JSON.parse(window.localStorage.getItem("offline-queue-v1") ?? "[]");
    expect(stored[0].id).toBe(first[0]?.id);
  });

  it("converts v1 payloads to the validated RPC shapes", async () => {
    window.localStorage.setItem("offline-queue-v1", JSON.stringify([
      { id: "1730000000000-0", createdAt: "2026-11-02T00:00:00Z", op: { kind: "deposit", payload: { salesman_id: "s1", amount: 700, note: "old" } } },
      { id: "1730000000000-1", createdAt: "2026-11-02T00:01:00Z", op: { kind: "retailer_payment", payload: { retailer_id: "r1", amount: 300 } } },
      { id: "1730000000000-2", createdAt: "2026-11-02T00:02:00Z", op: { kind: "record_sale", payload: { _retailer: "r1", _items: [], _paid: 10 } } },
    ]));
    const res = await replayQueue(null);
    expect(res.synced).toBe(3);
    const calls = rpc.mock.calls.map((c) => [c[0], c[1]]);
    expect(calls[0]).toEqual(["record_deposit", { _salesman: "s1", _amount: 700, _method: "cash", _note: "old", _date: null, _op: expect.any(String) }]);
    expect(calls[1]?.[0]).toBe("record_retailer_payment");
    expect(calls[2]?.[0]).toBe("record_sale");
    expect((calls[2]?.[1] as { _discount: number })._discount).toBe(0);
    expect(getQueue()).toHaveLength(0);
  });
});
