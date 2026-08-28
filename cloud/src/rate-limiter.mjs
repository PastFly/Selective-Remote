import { hashAbuseKey } from "./security.mjs";

export class AuthRateLimiter {
  constructor(store, config) {
    this.store = store;
    this.pepper = config.abuseTokenPepper;
    this.policies = config.authRateLimits;
  }

  async require(scope, value) {
    const policy = this.policies[scope];
    if (!policy) throw new Error("invalid_rate_limit_policy");
    const result = await this.store.consumeRateLimit({
      scope,
      keyHash: hashAbuseKey(scope, value, this.pepper),
      limit: policy.limit,
      windowSeconds: policy.windowSeconds,
    });
    if (!result.allowed) {
      const error = new Error("rate_limited");
      error.retryAfterSeconds = result.retryAfterSeconds;
      throw error;
    }
  }
}
