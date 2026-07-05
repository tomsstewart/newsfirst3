/**
 * APNs client: HTTP/2 + ES256 provider-token auth (the .p8 key, no certificates).
 * The JWT is cached ~50 min at module level (Apple accepts 20–60 min; a stale token
 * is TooManyProviderTokenUpdates bait if re-minted per send).
 */

export type ApnsEnv = {
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_TOPIC: string;
};

export type PushResult = { ok: boolean; apnsId?: string; reason?: string; status: number };

let cached: { jwt: string; at: number } | null = null;

const b64url = (bytes: Uint8Array | string): string =>
  btoa(typeof bytes === "string" ? bytes : String.fromCharCode(...bytes))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function providerJwt(env: ApnsEnv): Promise<string> {
  if (cached && Date.now() - cached.at < 50 * 60 * 1000) return cached.jwt;
  const pem = env.APNS_KEY_P8.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64url(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const claims = b64url(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) }));
  // WebCrypto ECDSA emits raw r||s — exactly what JWS ES256 wants (no DER wrangling).
  const sig = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${head}.${claims}`)));
  cached = { jwt: `${head}.${claims}.${b64url(sig)}`, at: Date.now() };
  return cached.jwt;
}

export async function sendPush(
  env: ApnsEnv,
  device: { token: string; environment: string },
  payload: unknown,
  collapseId?: string | null,
): Promise<PushResult> {
  const host = device.environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const headers: Record<string, string> = {
    authorization: `bearer ${await providerJwt(env)}`,
    "apns-topic": env.APNS_TOPIC,
    "apns-push-type": "alert",
    "apns-priority": "10",
    "apns-expiration": String(Math.floor(Date.now() / 1000) + 6 * 3600), // stale news ≠ news
    "content-type": "application/json",
  };
  if (collapseId) headers["apns-collapse-id"] = collapseId.slice(0, 64);
  const r = await fetch(`https://${host}/3/device/${device.token}`, {
    method: "POST", headers, body: JSON.stringify(payload),
  });
  if (r.ok) return { ok: true, apnsId: r.headers.get("apns-id") ?? undefined, status: r.status };
  let reason = "";
  try { reason = (await r.json()).reason ?? ""; } catch { /* non-JSON error body */ }
  return { ok: false, reason, status: r.status };
}
