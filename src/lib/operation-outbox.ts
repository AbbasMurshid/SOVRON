export type OutboxKind = "goal_contribution" | "debt_payment";

export type PendingOperation<T = unknown> = {
  ownerId: string;
  kind: OutboxKind;
  resourceId: string;
  operationId: string;
  payload: T;
  createdAt: string;
};

export interface OperationOutbox {
  get<T>(ownerId: string, kind: OutboxKind, resourceId: string): Promise<PendingOperation<T> | null>;
  put<T>(operation: PendingOperation<T>): Promise<PendingOperation<T>>;
  remove(ownerId: string, kind: OutboxKind, resourceId: string): Promise<void>;
  list(ownerId: string): Promise<PendingOperation[]>;
  clear(ownerId: string): Promise<void>;
}

const DATABASE = "myledger-operation-outbox";
const STORE = "pending-operations";
const DB_VERSION = 1;

function keyOf(ownerId: string, kind: OutboxKind, resourceId: string) {
  return `${ownerId}:${kind}:${resourceId}`;
}

function openOutbox(): Promise<IDBDatabase> {
  if (typeof indexedDB === "undefined") return Promise.reject(new Error("Persistent browser storage is unavailable."));
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE)) {
        const store = db.createObjectStore(STORE, { keyPath: "key" });
        store.createIndex("ownerId", "ownerId", { unique: false });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("Could not open the pending-operation store."));
  });
}

function withStore<T>(mode: IDBTransactionMode, action: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  return openOutbox().then(db => new Promise<T>((resolve, reject) => {
    const tx = db.transaction(STORE, mode);
    const request = action(tx.objectStore(STORE));
    let result: T;
    request.onsuccess = () => { result = request.result; };
    request.onerror = () => { db.close(); reject(request.error ?? new Error("Pending-operation storage failed.")); };
    tx.oncomplete = () => { db.close(); resolve(result); };
    tx.onerror = () => { db.close(); reject(tx.error ?? new Error("Pending-operation transaction failed.")); };
    tx.onabort = () => { db.close(); reject(tx.error ?? new Error("Pending-operation transaction was aborted.")); };
  }));
}

function putIfAbsent<T>(operation: PendingOperation<T>): Promise<PendingOperation<T>> {
  return openOutbox().then(db => new Promise<PendingOperation<T>>((resolve, reject) => {
    const tx = db.transaction(STORE, "readwrite");
    const store = tx.objectStore(STORE);
    const key = keyOf(operation.ownerId, operation.kind, operation.resourceId);
    let result: PendingOperation<T> = operation;
    const request = store.get(key);
    request.onsuccess = () => {
      if (request.result) {
        result = Object.fromEntries(Object.entries(request.result).filter(([field]) => field !== "key")) as PendingOperation<T>;
      } else {
        store.add({ ...operation, key });
      }
    };
    request.onerror = () => { db.close(); reject(request.error ?? new Error("Could not read pending operation.")); };
    tx.oncomplete = () => { db.close(); resolve(result); };
    tx.onerror = () => { db.close(); reject(tx.error ?? new Error("Could not persist pending operation.")); };
    tx.onabort = () => { db.close(); reject(tx.error ?? new Error("Pending-operation transaction was aborted.")); };
  }));
}

export const browserOperationOutbox: OperationOutbox = {
  async get<T>(ownerId: string, kind: OutboxKind, resourceId: string) {
    const result = await withStore<PendingOperation<T> | undefined>("readonly", store => store.get(keyOf(ownerId, kind, resourceId)));
    return result ?? null;
  },
  async put<T>(operation: PendingOperation<T>) {
    return putIfAbsent(operation);
  },
  async remove(ownerId: string, kind: OutboxKind, resourceId: string) {
    await withStore<undefined>("readwrite", store => store.delete(keyOf(ownerId, kind, resourceId)));
  },
  async list(ownerId: string) {
    const all = await withStore<(PendingOperation & { key: string })[]>("readonly", store => store.index("ownerId").getAll(ownerId));
    return all.map(entry => Object.fromEntries(Object.entries(entry).filter(([field]) => field !== "key")) as PendingOperation);
  },
  async clear(ownerId: string) {
    const db = await openOutbox();
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(STORE, "readwrite");
      const request = tx.objectStore(STORE).index("ownerId").openCursor(IDBKeyRange.only(ownerId));
      request.onsuccess = () => {
        const cursor = request.result;
        if (!cursor) return;
        cursor.delete();
        cursor.continue();
      };
      tx.oncomplete = () => { db.close(); resolve(); };
      tx.onerror = () => { db.close(); reject(tx.error ?? new Error("Could not clear pending operations.")); };
      tx.onabort = () => { db.close(); reject(tx.error ?? new Error("Could not clear pending operations.")); };
    });
  },
};
