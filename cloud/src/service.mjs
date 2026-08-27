import {
  createSessionToken,
  hashEmailVerificationToken,
  hashPassword,
  hashSessionToken,
  isUUID,
  normalizeEmail,
  validatePassword,
  validateVaultEnvelope,
  verifyPassword,
} from "./security.mjs";

export class CloudService {
  constructor(store, config) {
    this.store = store;
    this.config = config;
  }

  sessionExpiry() {
    return new Date(Date.now() + this.config.sessionTTLDays * 86_400_000);
  }

  validateDevice(value) {
    const device = value && typeof value === "object" ? value : {};
    if (!isUUID(device.id)) throw new Error("invalid_device");
    const name = String(device.name ?? "").trim();
    const platform = String(device.platform ?? "").trim();
    if (!name || name.length > 120 || !platform || platform.length > 80) throw new Error("invalid_device");
    return {
      id: device.id.toLowerCase(),
      name,
      platform,
      appVersion: String(device.appVersion ?? "").slice(0, 40),
      publicKey: device.publicKey ? String(device.publicKey).slice(0, 4096) : null,
    };
  }

  async register(input) {
    if (!this.config.allowRegistration) throw new Error("registration_disabled");
    const email = normalizeEmail(input.email);
    const password = validatePassword(input.password);
    const displayName = String(input.displayName ?? "").trim().slice(0, 120);
    const device = this.validateDevice(input.device);
    const token = createSessionToken();
    const passwordHash = await hashPassword(password);
    const user = await this.store.createUser({
      email,
      displayName,
      passwordHash,
      device,
      sessionHash: hashSessionToken(token, this.config.sessionPepper),
      expiresAt: this.sessionExpiry(),
    });
    return { token, user: publicUser(user), deviceID: device.id };
  }

  async login(input) {
    const email = normalizeEmail(input.email);
    const password = validatePassword(input.password);
    const identity = await this.store.passwordIdentity(email);
    if (!identity || identity.disabled_at || !(await verifyPassword(password, identity.password_hash))) {
      throw new Error("invalid_credentials");
    }
    const device = this.validateDevice(input.device);
    const token = createSessionToken();
    await this.store.createSession({
      userID: identity.id,
      device,
      sessionHash: hashSessionToken(token, this.config.sessionPepper),
      expiresAt: this.sessionExpiry(),
    });
    return { token, user: publicUser(identity), deviceID: device.id };
  }

  async verifyEmail(input) {
    const tokenHash = hashEmailVerificationToken(
      input?.token,
      this.config.emailVerificationPepper,
    );
    const user = await this.store.consumeEmailVerificationToken(tokenHash);
    if (!user) throw new Error("invalid_verification_token");
    return { verified: true };
  }

  async authenticate(token) {
    if (!token || token.length > 256) return null;
    return this.store.session(hashSessionToken(token, this.config.sessionPepper));
  }

  async getVault(session) {
    const vault = await this.store.getVault(session.user_id);
    if (!vault) throw new Error("vault_missing");
    return {
      id: vault.id,
      revision: Number(vault.revision),
      envelopeVersion: vault.envelope_version,
      wrappedKey: vault.wrapped_key,
      ciphertext: vault.ciphertext,
      nonce: vault.nonce,
      authTag: vault.auth_tag,
      contentHash: vault.content_hash,
      updatedAt: vault.updated_at,
    };
  }

  async putVault(session, input) {
    return this.store.putVault(session.user_id, session.device_id, validateVaultEnvelope(input));
  }
}

function publicUser(row) {
  return { id: row.id, email: row.email, displayName: row.display_name, createdAt: row.created_at };
}
