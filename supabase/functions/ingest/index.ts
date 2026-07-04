/**
 * NewsFirst v3 ingest — Supabase Edge Function (Deno).
 * Invoked by pg_cron via pg_net: ?task=ingest every 5 min, ?task=watchdog hourly.
 * Tick: pick due sources → conditional GET → parse → dedupe → enrich → score once → insert.
 * Health: exponential backoff + auto-fix ladder; nothing is ever silently disabled (v2's sin).
 * Scoring is write-once; decay/tiers are computed at read time in Postgres — unlike v2,
 * this function issues ZERO article updates.
 *
 * Secrets: SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY are auto-injected by the platform;
 * set GEMINI_API_KEY via `supabase secrets set` or Dashboard → Edge Functions → Secrets.
 */

export interface Env {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
  GEMINI_API_KEY: string;
}

interface Source {
  id: string; name: string; feed_url: string; category: string; weight: number;
  region: string | null; etag: string | null; last_modified: string | null;
  fail_streak: number; health: string; poll_interval_s: number;
}

interface Item {
  url: string; url_hash: string; title: string; excerpt: string | null;
  image_url: string | null; published_at: string; source_id: string;
  topics: string[]; entities: string[]; regions: string[];
  base_score: number; score_breakdown: Record<string, number>; lang: string | null;
}

// ---------- Supabase REST helpers (service role) ----------
const sb = (env: Env) => ({
  async get<T>(path: string): Promise<T> {
    const r = await fetch(`${env.SUPABASE_URL}/rest/v1/${path}`, { headers: hdrs(env) });
    if (!r.ok) throw new Error(`GET ${path}: ${r.status}`);
    return r.json();
  },
  async post(path: string, body: unknown, prefer = "return=minimal"): Promise<void> {
    const r = await fetch(`${env.SUPABASE_URL}/rest/v1/${path}`, {
      method: "POST", headers: { ...hdrs(env), Prefer: prefer }, body: JSON.stringify(body),
    });
    if (!r.ok && r.status !== 409) throw new Error(`POST ${path}: ${r.status} ${await r.text()}`);
  },
  async patch(path: string, body: unknown): Promise<void> {
    const r = await fetch(`${env.SUPABASE_URL}/rest/v1/${path}`, {
      method: "PATCH", headers: hdrs(env), body: JSON.stringify(body),
    });
    if (!r.ok) throw new Error(`PATCH ${path}: ${r.status}`);
  },
});
const hdrs = (env: Env) => ({
  apikey: env.SUPABASE_SERVICE_KEY,
  Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
  "Content-Type": "application/json",
});

// ---------- scoring (write-once; mirrors strategy §7.3) ----------
const HARD_BOOSTS = ["breaking", "exclusive", "just in", "breach", "outage", "resigns", "dies", "war", "election result"];
const DEMOTE = [/\bdeal(s)?\b.*\b(save|off|discount)\b/i, /\btop \d+\b/i, /\bbest .* to buy\b/i, /\breview\b:?/i, /\bhow to\b/i];

export function baseScore(title: string, weight: number): { score: number; breakdown: Record<string, number> } {
  const b: Record<string, number> = {};
  b.source = weight >= 5 ? 30 : weight === 4 ? 20 : weight === 3 ? 10 : 5;
  const t = title.toLowerCase();
  if (HARD_BOOSTS.some((k) => t.includes(k))) b.boost = 30;
  if (DEMOTE.some((re) => re.test(title))) b.demoted = -100;
  const score = Math.max(0, Math.min(100, Object.values(b).reduce((a, x) => a + x, 0)));
  return { score, breakdown: b };
}

// ---------- RSS/Atom parsing (tolerant, dependency-free) ----------
export function parseFeed(xml: string): { title: string; link: string; pubDate?: string; description?: string; image?: string }[] {
  const items: ReturnType<typeof parseFeed> = [];
  const blocks = xml.match(/<(item|entry)[\s\S]*?<\/\1>/g) ?? [];
  for (const b of blocks.slice(0, 50)) {
    const tag = (n: string) => {
      const m = b.match(new RegExp(`<${n}[^>]*>([\\s\\S]*?)</${n}>`, "i"));
      return m ? decode(m[1].replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1").trim()) : undefined;
    };
    const linkAttr = b.match(/<link[^>]*href="([^"]+)"/i)?.[1];
    const title = tag("title");
    const link = tag("link") || linkAttr;
    if (!title || !link) continue;
    const image =
      b.match(/<media:content[^>]*url="([^"]+)"/i)?.[1] ??
      b.match(/<media:thumbnail[^>]*url="([^"]+)"/i)?.[1] ??
      b.match(/<enclosure[^>]*url="([^"]+\.(?:jpg|jpeg|png|webp)[^"]*)"/i)?.[1];
    items.push({ title, link, pubDate: tag("pubDate") ?? tag("published") ?? tag("dc:date"), description: tag("description") ?? tag("summary"), image });
  }
  return items;
}
const decode = (s: string) =>
  s.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'").replace(/<[^>]+>/g, "").trim();

export function normalizeUrl(raw: string): string {
  try {
    const u = new URL(raw);
    ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "fbclid", "gclid", "ref"].forEach((p) => u.searchParams.delete(p));
    u.hash = "";
    return u.toString();
  } catch { return raw; }
}

async function sha256(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ---------- Gemini enrichment (batched; free tier) ----------
async function enrich(env: Env, items: { title: string; excerpt: string | null }[]): Promise<{ topics: string[]; entities: string[]; regions: string[] }[]> {
  if (items.length === 0) return [];
  const prompt = `For each numbered news headline below, return a JSON array (same order, same length) of objects:
{"topics": [1-3 slugs from: world,business,economics,tech,ai,science,sports,space,climate,entertainment,travel,crypto,health,gaming],
 "entities": [lowercased key people/companies/products, max 5],
 "regions": [ISO-3166 alpha-2 codes the story is ABOUT, max 3, often empty]}
Headlines:
${items.map((it, i) => `${i + 1}. ${it.title} — ${it.excerpt?.slice(0, 140) ?? ""}`).join("\n")}
Return ONLY the JSON array.`;
  try {
    const r = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent?key=${env.GEMINI_API_KEY}`,
      { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ contents: [{ parts: [{ text: prompt }] }], generationConfig: { responseMimeType: "application/json", temperature: 0 } }) },
    );
    if (!r.ok) throw new Error(`gemini ${r.status}`);
    const j: any = await r.json();
    const arr = JSON.parse(j.candidates[0].content.parts[0].text);
    if (Array.isArray(arr) && arr.length === items.length) return arr;
    throw new Error("shape mismatch");
  } catch {
    // Enrichment is an enhancement, not a dependency — fall back to source category only.
    return items.map(() => ({ topics: [], entities: [], regions: [] }));
  }
}

// ---------- health / auto-fix ladder ----------
async function fetchFeed(src: Source): Promise<{ status: number; body?: string; finalUrl?: string }> {
  const attempt = (headers: Record<string, string>) =>
    fetch(src.feed_url, { headers, redirect: "follow", signal: AbortSignal.timeout(8000) });
  const cond: Record<string, string> = { "User-Agent": "NewsFirst/3.0 (+https://www.getnewsfirst.app)" };
  if (src.etag) cond["If-None-Match"] = src.etag;
  if (src.last_modified) cond["If-Modified-Since"] = src.last_modified;

  let r = await attempt(cond).catch(() => null);
  // Auto-fix step 1: plain UA, no conditional headers
  if (!r || (r.status >= 400 && r.status !== 404)) {
    r = await attempt({ "User-Agent": "Mozilla/5.0 (compatible; NewsFirstBot/3.0)" }).catch(() => null);
  }
  if (!r) return { status: 0 };
  if (r.status === 304) return { status: 304 };
  const finalUrl = r.url !== src.feed_url ? r.url : undefined; // auto-fix step 2: persist permanent moves
  return { status: r.status, body: r.ok ? await r.text() : undefined, finalUrl };
}

function backoffSeconds(failStreak: number): number {
  return Math.min(600 * 2 ** Math.max(0, failStreak - 3), 6 * 3600); // kicks in from 3rd failure, caps 6h
}

// ---------- main tick ----------
async function ingestTick(env: Env): Promise<void> {
  const db = sb(env);
  const started = new Date().toISOString();
  const due = await db.get<Source[]>(
    `sources?is_enabled=eq.true&or=(backoff_until.is.null,backoff_until.lt.${started})` +
    `&select=id,name,feed_url,category,weight,region,etag,last_modified,fail_streak,health,poll_interval_s` +
    `&order=last_fetch_at.asc.nullsfirst&limit=15`,
  );

  let inserted = 0, failed = 0;
  for (const src of due) {
    const now = new Date().toISOString();
    try {
      const res = await fetchFeed(src);
      if (res.status === 304) {
        await db.patch(`sources?id=eq.${src.id}`, { last_fetch_at: now, last_success_at: now, fail_streak: 0, health: "ok", backoff_until: null, poll_interval_s: Math.min(src.poll_interval_s * 1.5, 21600) | 0 });
        continue;
      }
      if (!res.body) throw new Error(`http ${res.status}`);

      const parsed = parseFeed(res.body);
      const candidates: Item[] = [];
      for (const p of parsed) {
        const url = normalizeUrl(p.link);
        const published = p.pubDate && !isNaN(Date.parse(p.pubDate)) ? new Date(p.pubDate).toISOString() : now; // never NULL (v2 bug)
        const { score, breakdown } = baseScore(p.title, src.weight);
        candidates.push({
          url, url_hash: await sha256(url), title: p.title.slice(0, 300),
          excerpt: p.description?.slice(0, 500) ?? null,
          image_url: p.image ?? null, published_at: published, source_id: src.id,
          topics: [src.category], entities: [], regions: src.region ? [src.region] : [],
          base_score: score, score_breakdown: breakdown, lang: null,
        });
      }
      if (candidates.length) {
        const meta = await enrich(env, candidates);
        meta.forEach((m, i) => {
          candidates[i].topics = [...new Set([...candidates[i].topics, ...m.topics])];
          candidates[i].entities = m.entities;
          candidates[i].regions = [...new Set([...candidates[i].regions, ...m.regions])];
        });
        await db.post("articles?on_conflict=url_hash", candidates, "resolution=ignore-duplicates,return=minimal");
        inserted += candidates.length;
      }
      await db.patch(`sources?id=eq.${src.id}`, {
        last_fetch_at: now, last_success_at: now, fail_streak: 0, health: "ok", backoff_until: null,
        ...(candidates.length ? { last_new_item_at: now, poll_interval_s: Math.max(300, (src.poll_interval_s / 2) | 0) } : { poll_interval_s: Math.min((src.poll_interval_s * 1.5) | 0, 21600) }),
        ...(res.finalUrl ? { feed_url: res.finalUrl } : {}),
      });
    } catch (e) {
      failed++;
      const streak = src.fail_streak + 1;
      await db.patch(`sources?id=eq.${src.id}`, {
        last_fetch_at: now, fail_streak: streak,
        health: streak >= 3 ? "degraded" : src.health,
        backoff_until: streak >= 3 ? new Date(Date.now() + backoffSeconds(streak) * 1000).toISOString() : null,
      }).catch(() => {});
    }
  }

  await db.post("ingest_runs", { started_at: started, finished_at: new Date().toISOString(), sources_polled: due.length, sources_failed: failed, articles_inserted: inserted });
  // TODO(phase 4): alert matcher — new articles × topic_subscriptions (notify_level high/all) → APNs.
  // TODO(phase 4): cluster velocity — assign cluster_id via entity overlap; ≥3 sources/45min ⇒ breaking.
}

async function healthWatchdog(env: Env): Promise<void> {
  const db = sb(env);
  const cutoff = new Date(Date.now() - 48 * 3600 * 1000).toISOString();
  const stale = await db.get<Source[]>(`sources?is_enabled=eq.true&health=neq.broken&last_success_at=lt.${cutoff}&select=id,name`);
  for (const s of stale) await db.patch(`sources?id=eq.${s.id}`, { health: "broken" });
  // TODO(phase 2): re-discovery from homepage <link rel="alternate"> for broken sources.
  // TODO(phase 4): push "source broken: <name>" to the owner through the app's own alert pipeline.
  // TODO(phase 4): digest generation at each user's digest_hour.
}

Deno.serve(async (req: Request) => {
  const env: Env = {
    SUPABASE_URL: Deno.env.get("SUPABASE_URL")!,
    SUPABASE_SERVICE_KEY: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    GEMINI_API_KEY: Deno.env.get("GEMINI_API_KEY") ?? "",
  };
  // Only the service role may trigger ingestion (verify_jwt alone would admit the public anon key).
  const bearer = req.headers.get("Authorization")?.replace("Bearer ", "");
  if (bearer !== env.SUPABASE_SERVICE_KEY) {
    return new Response("forbidden", { status: 403 });
  }
  const task = new URL(req.url).searchParams.get("task") ?? "ingest";
  if (task === "watchdog") await healthWatchdog(env);
  else await ingestTick(env);
  return new Response(JSON.stringify({ ok: true, task }), { headers: { "Content-Type": "application/json" } });
});
