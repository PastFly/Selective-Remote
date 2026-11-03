// Existing isolated tests exercise storage after the user has acknowledged the
// one-time transition. Compatibility tests use the raw factory instead.
import { IDBFactory as FakeIDBFactory } from "fake-indexeddb";
import { authorizeVaultStorageUpgrade } from "../public/vault-storage.js";

export class IDBFactory extends FakeIDBFactory {
  constructor() {
    super();
    authorizeVaultStorageUpgrade(this);
  }
}
