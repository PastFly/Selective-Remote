import {
  createEmailVerificationToken,
  createPasswordResetToken,
  createSessionToken,
  hashEmailVerificationToken,
  hashPassword,
  hashPasswordResetToken,
  hashSessionToken,
  isUUID,
  normalizeEmail,
  validatePassword,
  validateVaultEnvelope,
  verifyPassword,
} from "./security.mjs";

export class CloudService {
  constructor(store, config, mailer = null, logger = console) {
    this.store = store;
    this.config = config;
    this.mailer = mailer;
    this.logger = logger;
  }

  sessionExpiry() {
    return new Date(Date.now() + this.config.sessionTTLDays * 86_400_000);
  }

  emailVerificationExpiry() {
    return new Date(Date.now() + this.config.emailVerificationTTLHours * 3_600_000);
  }

  passwordResetExpiry() {
    return new Date(Date.now() + this.config.passwordResetTTLHours * 3_600_000);
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
    if (!this.mailer) throw new Error("smtp_not_configured");
    const email = normalizeEmail(input.email);
    const password = validatePassword(input.password);
    const displayName = String(input.displayName ?? "").trim().slice(0, 120);
    const device = this.validateDevice(input.device);
    const verificationToken = createEmailVerificationToken();
    const passwordHash = await hashPassword(password);
    const user = await this.store.createUser({
      email,
      displayName,
      passwordHash,
      device,
      verificationHash: hashEmailVerificationToken(
        verificationToken,
        this.config.emailVerificationPepper,
      ),
      verificationExpiresAt: this.emailVerificationExpiry(),
    });
    try {
      await this.mailer.sendEmailVerification({ recipient: email, token: verificationToken });
    } catch {
      this.logger.warn(JSON.stringify({ level: "warn", message: "Verification email delivery failed" }));
      throw new Error("email_delivery_failed");
    }
    return { verificationRequired: true, user: publicUser(user) };
  }

  async login(input) {
    const email = normalizeEmail(input.email);
    const password = validatePassword(input.password);
    const identity = await this.store.passwordIdentity(email);
    if (!identity || identity.disabled_at || !(await verifyPassword(password, identity.password_hash))) {
      throw new Error("invalid_credentials");
    }
    if (!identity.email_verified_at) throw new Error("email_not_verified");
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

  async resendEmailVerification(input) {
    if (!this.mailer) throw new Error("smtp_not_configured");
    const email = normalizeEmail(input.email);
    const identity = await this.store.passwordIdentity(email);
    if (!identity || identity.disabled_at || identity.email_verified_at) {
      return { accepted: true };
    }

    const token = createEmailVerificationToken();
    const replaced = await this.store.replaceEmailVerificationToken({
      userID: identity.id,
      tokenHash: hashEmailVerificationToken(token, this.config.emailVerificationPepper),
      expiresAt: this.emailVerificationExpiry(),
    });
    if (!replaced) return { accepted: true };
    try {
      await this.mailer.sendEmailVerification({ recipient: email, token });
    } catch {
      this.logger.warn(JSON.stringify({ level: "warn", message: "Verification email delivery failed" }));
    }
    return { accepted: true };
  }

  async requestPasswordReset(input) {
    if (!this.mailer) throw new Error("smtp_not_configured");
    const email = normalizeEmail(input.email);
    const identity = await this.store.passwordIdentity(email);
    if (!identity || identity.disabled_at || !identity.email_verified_at) {
      return { accepted: true };
    }

    const token = createPasswordResetToken();
    const replaced = await this.store.replacePasswordResetToken({
      userID: identity.id,
      tokenHash: hashPasswordResetToken(token, this.config.passwordResetTokenPepper),
      expiresAt: this.passwordResetExpiry(),
    });
    if (!replaced) return { accepted: true };
    try {
      await this.mailer.sendPasswordReset({ recipient: email, token });
    } catch {
      this.logger.warn(JSON.stringify({ level: "warn", message: "Password reset email delivery failed" }));
    }
    return { accepted: true };
  }

  async resetPassword(input) {
    const password = validatePassword(input.password);
    const tokenHash = hashPasswordResetToken(input.token, this.config.passwordResetTokenPepper);
    const identity = await this.store.passwordResetIdentity(tokenHash);
    if (!identity) throw new Error("invalid_password_reset_token");
    const passwordHash = await hashPassword(password);
    const consumed = await this.store.consumePasswordResetToken({
      userID: identity.user_id,
      tokenHash,
      passwordHash,
    });
    if (!consumed) throw new Error("invalid_password_reset_token");
    return { reset: true };
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
