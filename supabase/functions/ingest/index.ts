/**
 * NewsFirst v3 ingest — Supabase Edge Function (Deno).
 * Invoked by pg_cron via pg_net: ?task=ingest every 5 min, ?task=watchdog hourly.
 * Tick: pick due sources → conditional GET → parse → dedupe → enrich → score once → insert.
 * Health: exponential backoff + auto-fix ladder; nothing is ever silently disabled (v2's sin).
 * Scoring is write-once; decay/tiers are computed at read time in Postgres — unlike v2,
 * this function issues ZERO article updates.
 *
 * Secrets: SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY are auto-injected by the platform;
 * set GEMINI_API_KEY + APNS_* via `supabase secrets set` or Dashboard → Edge Functions → Secrets.
 */
import { sendPush } from "./apns.ts";

export interface Env {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
  GEMINI_API_KEY: string;
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_TOPIC: string;
}

interface Source {
  id: string; name: string; feed_url: string; category: string; weight: number;
  region: string | null; etag: string | null; last_modified: string | null;
  fail_streak: number; health: string; poll_interval_s: number;
}

interface Item {
  url: string; url_hash: string; title: string; excerpt: string | null;
  image_url: string | null; image_status: string; published_at: string; source_id: string;
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
  /// Insert returning the rows that actually landed (duplicates excluded) — honest counts.
  async postRows(path: string, body: unknown, prefer: string): Promise<unknown[]> {
    const r = await fetch(`${env.SUPABASE_URL}/rest/v1/${path}`, {
      method: "POST", headers: { ...hdrs(env), Prefer: prefer }, body: JSON.stringify(body),
    });
    if (!r.ok && r.status !== 409) throw new Error(`POST ${path}: ${r.status} ${await r.text()}`);
    return r.ok ? r.json() : [];
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
// Keyword boosts retired (ranking v2): multi-source cluster velocity is the importance
// signal now — computed in Postgres (assign_clusters + feed view), immune to headline
// keyword games. Demotions stay: listicles/deals are low-value regardless of sources.
const DEMOTE = [/\bdeal(s)?\b.*\b(save|off|discount)\b/i, /\btop \d+\b/i, /\bbest .* to buy\b/i, /\breview\b:?/i, /\bhow to\b/i];

export function baseScore(title: string, weight: number): { score: number; breakdown: Record<string, number> } {
  const b: Record<string, number> = {};
  b.source = weight >= 5 ? 30 : weight === 4 ? 20 : weight === 3 ? 10 : 5;
  if (DEMOTE.some((re) => re.test(title))) b.demoted = -100;
  const score = Math.max(0, Math.min(100, Object.values(b).reduce((a, x) => a + x, 0)));
  return { score, breakdown: b };
}

// Conservative keyword hints: a zero-cost topic layer between "which feed is this from"
// and the quota-limited Gemini pass. High-precision terms only — a wrong topic is worse
// than a missing one. Articles hinted here reach 2 topics and skip enrichment (saves quota).
const TOPIC_HINTS: [string, RegExp][] = [
  ["ai", /\b(ai|artificial intelligence|openai|chatgpt|anthropic|claude|gemini|llms?|machine learning)\b/i],
  ["crypto", /\b(bitcoin|btc|ethereum|crypto(currenc\w*)?|blockchain|stablecoins?|defi)\b/i],
  ["climate", /\b(climate|heatwaves?|wildfires?|emissions|global warming|drought|el ni[ñn]o)\b/i],
  ["space", /\b(nasa|spacex|rockets?|asteroids?|orbit(al)?|mars|satellites?|telescope)\b/i],
  ["health", /\b(cancer|vaccines?|nhs|diabetes|obesity|mental health|outbreak|virus)\b/i],
  ["economics", /\b(inflation|gdp|interest rates?|central bank|recession|tariffs?|federal reserve)\b/i],
  ["sports", /\b(premier league|nba|nfl|olympics?|world cup|grand slam|formula 1|f1)\b/i],
  ["gaming", /\b(playstation|ps5|xbox|nintendo|steam deck|esports)\b/i],
];

export function hintTopics(title: string, category: string): string[] {
  const hit = TOPIC_HINTS.find(([topic, re]) => topic !== category && re.test(title));
  return hit ? [category, hit[0]] : [category];
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
    // XML attribute values are entity-escaped: URLs with query strings arrive as
    // &amp; and MUST be decoded or signed CDN URLs (Guardian) 404 forever.
    const attr = (s?: string) => s?.replace(/&amp;/g, "&").replace(/&#0*38;/g, "&");
    const linkAttr = attr(b.match(/<link[^>]*href="([^"]+)"/i)?.[1]);
    const title = tag("title");
    const link = tag("link") || linkAttr;
    if (!title || !link) continue;
    // Feeds often list several media:content renditions — take the LARGEST (Guardian
    // leads with a 140px thumbnail; first-match shipped postage stamps).
    const renditions = [...b.matchAll(/<media:content[^>]*?url="([^"]+)"[^>]*?>/gi)]
      .map((m) => ({ url: m[1], width: Number(m[0].match(/width="(\d+)"/)?.[1] ?? 0) }))
      .sort((a, z) => z.width - a.width);
    const image = attr(
      renditions[0]?.url ??
      b.match(/<media:thumbnail[^>]*url="([^"]+)"/i)?.[1] ??
      b.match(/<enclosure[^>]*url="([^"]+\.(?:jpg|jpeg|png|webp)[^"]*)"/i)?.[1] ??
      b.match(/<img[^>]+src=["']([^"']+\.(?:jpg|jpeg|png|webp)[^"']*)["']/i)?.[1],   // e.g. The Verge: image only in description HTML
    );
    items.push({ title, link, pubDate: tag("pubDate") ?? tag("published") ?? tag("dc:date"), description: tag("description") ?? tag("summary"), image });
  }
  return items;
}
const decode = (s: string) =>
  s.replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
   .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)))
   .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'").replace(/&nbsp;/g, " ")
   .replace(/<[^>]+>/g, "").trim();

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
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function enrichChunk(env: Env, items: { title: string; excerpt: string | null }[], attempt = 0): Promise<{ topics: string[]; entities: string[]; regions: string[] }[]> {
  if (items.length === 0) return [];
  const prompt = `For each numbered news headline below, return a JSON array (same order, same length) of objects:
{"topics": [THE single best-fitting slug from: world,business,economics,tech,ai,science,sports,space,climate,entertainment,travel,crypto,health,gaming — plus AT MOST one secondary slug ONLY when the story is genuinely about both; when unsure use fewer topics],
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
    // 429 = RPM window; 5xx = "high demand" load-shedding (the 2026-07-05 briefs killer).
    if ((r.status === 429 || r.status >= 500) && attempt < 2) {
      await sleep(8000 * (attempt + 1));
      return enrichChunk(env, items, attempt + 1);
    }
    if (!r.ok) throw new Error(`gemini ${r.status}`);
    const j: any = await r.json();
    const arr = JSON.parse(geminiText(j));
    if (Array.isArray(arr) && arr.length === items.length) return arr;
    throw new Error("shape mismatch");
  } catch (e) {
    // Enrichment is an enhancement, not a dependency — fall back to source category only.
    console.error("enrich:", e instanceof Error ? e.message : e);
    return items.map(() => ({ topics: [], entities: [], regions: [] }));
  }
}

/// Long JSON responses can arrive split across parts; missing candidates = explicit error.
function geminiText(j: any): string {
  const parts = j?.candidates?.[0]?.content?.parts;
  if (!Array.isArray(parts)) throw new Error(`gemini empty response: ${JSON.stringify(j).slice(0, 300)}`);
  return parts.map((p: any) => p.text ?? "").join("");
}

/// Semantic embeddings for clustering via Supabase's BUILT-IN gte-small model
/// (384-dim, runs locally in the edge runtime): zero quota, zero API keys — the
/// Gemini per-item free-tier limit made remote embedding a non-starter (live 429
/// after one batch). Embeddings lag ingest by at most one tick; merge_clusters
/// retro-heals anything the trigram fallback mis-assigned in that gap.
// deno-lint-ignore no-explicit-any
declare const Supabase: any;
const gte = new Supabase.ai.Session("gte-small");

async function embedNewArticles(env: Env, limit = 12): Promise<number> {
  // 12/invocation stays inside the free edge worker's CPU budget (100 hit
  // WORKER_RESOURCE_LIMIT); its own 5-min cron gives ~3.4k/day capacity vs ~2.5k new articles.
  const db = sb(env);
  const since = new Date(Date.now() - 36 * 3600 * 1000).toISOString();
  const rows = await db.get<{ id: string; title: string; excerpt: string | null }[]>(
    `articles?embedding=is.null&published_at=gt.${since}&select=id,title,excerpt&order=published_at.desc&limit=${limit}`,
  );
  let stored = 0;
  try {
    for (const r of rows) {
      const emb = await gte.run(`${r.title}\n${r.excerpt?.slice(0, 200) ?? ""}`, { mean_pool: true, normalize: true }) as number[];
      if (!emb?.length) continue;
      await db.patch(`articles?id=eq.${r.id}`, { embedding: `[${emb.join(",")}]` }).catch(() => {});
      stored++;
    }
    return stored;
  } catch (e) {
    console.error("embed:", e instanceof Error ? e.message : e);
    return stored > 0 ? stored : -1;   // partial progress still counts; next tick continues
  }
}

async function ogImage(pageUrl: string): Promise<string | null> {
  try {
    const r = await fetch(pageUrl, { headers: { "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" }, redirect: "follow", signal: AbortSignal.timeout(5000) });
    if (!r.ok || !r.body) return null;
    // Stream only the head — og:image lives there; never download whole multi-MB pages.
    const reader = r.body.getReader();
    const chunks: Uint8Array[] = [];
    let got = 0;
    while (got < 120_000) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value); got += value.length;
    }
    reader.cancel().catch(() => {});
    const head = new TextDecoder().decode(concat(chunks)).slice(0, 120_000);
    const m = head.match(/<meta[^>]+property=["']og:image(?::url)?["'][^>]+content=["']([^"']+)["']/i) ??
              head.match(/<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image(?::url)?["']/i) ??
              head.match(/<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']/i);
    return m ? m[1] : null;
  } catch { return null; }
}

function concat(chunks: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
  let off = 0;
  for (const c of chunks) { out.set(c, off); off += c.length; }
  return out;
}

// ---------- health / auto-fix ladder ----------
async function fetchFeed(src: Source): Promise<{ status: number; body?: string; finalUrl?: string; etag?: string; lastModified?: string }> {
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
  return {
    status: r.status, body: r.ok ? await r.text() : undefined, finalUrl,
    // Persisting these is what makes the conditional headers above ever fire.
    etag: r.headers.get("etag") ?? undefined,
    lastModified: r.headers.get("last-modified") ?? undefined,
  };
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
        // Clamp to now: future pubDates (typos, wrong-tz feeds) would pin the freshness
        // multiplier at max indefinitely and dodge the retention purge.
        const published = p.pubDate && !isNaN(Date.parse(p.pubDate)) && Date.parse(p.pubDate) < Date.now()
          ? new Date(p.pubDate).toISOString() : now; // never NULL (v2 bug)
        const { score, breakdown } = baseScore(p.title, src.weight);
        candidates.push({
          url, url_hash: await sha256(url), title: p.title.slice(0, 300),
          excerpt: p.description?.slice(0, 500) ?? null,
          // image_status on EVERY row: PostgREST bulk insert demands identical keys, and
          // setting it only on OG-rescued rows 400'd whole batches (took Al Jazeera down).
          image_url: p.image ?? null, image_status: "unchecked", published_at: published, source_id: src.id,
          topics: hintTopics(p.title, src.category), entities: [], regions: src.region ? [src.region] : [],
          base_score: score, score_breakdown: breakdown, lang: null,
        });
      }
      if (candidates.length) {
        // Bounded OG-image rescue for imageless items (v2 did this unbounded — that burned compute)
        let ogBudget = 8;
        for (const c of candidates) {
          if (!c.image_url && ogBudget > 0) { ogBudget--; c.image_url = await ogImage(c.url); if (c.image_url) c.image_status = "ok"; }
        }
        // No inline AI here: Gemini free tier is 20 req/DAY — enrichment runs as the
        // scheduled enrich_backfill batch (1 call of 100 headlines / 2h) instead.
        const landed = await db.postRows("articles?on_conflict=url_hash&select=id", candidates, "resolution=ignore-duplicates,return=representation");
        inserted += landed.length;   // real inserts only, not the ~95% duplicates
      }
      await db.patch(`sources?id=eq.${src.id}`, {
        last_fetch_at: now, last_success_at: now, fail_streak: 0, health: "ok", backoff_until: null,
        etag: res.etag ?? null, last_modified: res.lastModified ?? null,
        ...(candidates.length ? { last_new_item_at: now, poll_interval_s: Math.max(300, (src.poll_interval_s / 2) | 0) } : { poll_interval_s: Math.min((src.poll_interval_s * 1.5) | 0, 21600) }),
      });
      // Separate + tolerated: a redirect target that equals another source's feed_url
      // violates the unique constraint; that must never fail the whole (healthy) poll.
      if (res.finalUrl) await db.patch(`sources?id=eq.${src.id}`, { feed_url: res.finalUrl }).catch(() => {});
    } catch (e) {
      failed++;
      // Name the failure — silent per-source catches hid Al Jazeera being down for a day.
      console.error(`ingest ${src.name}:`, e instanceof Error ? e.message : e);
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
  // Image rescue: OG-fetch recent imageless articles (cron hourly; callable ad hoc).
  const recent = new Date(Date.now() - 30 * 24 * 3600 * 1000).toISOString();
  const imageless = await db.get<{ id: string; url: string }[]>(
    `articles?image_url=is.null&image_status=neq.none&published_at=gt.${recent}&select=id,url&order=published_at.desc&limit=40`,
  ).catch(() => [] as { id: string; url: string }[]);
  for (const a of imageless) {
    const img = await ogImage(a.url);
    if (img) await db.patch(`articles?id=eq.${a.id}`, { image_url: img, image_status: "ok" }).catch(() => {});
    else await db.patch(`articles?id=eq.${a.id}`, { image_status: "none" }).catch(() => {});   // stop retrying hopeless ones
  }
  const cutoff = new Date(Date.now() - 48 * 3600 * 1000).toISOString();
  // NULL last_success_at (never-succeeded source, e.g. bad seed URL) must also surface.
  const stale = await db.get<Source[]>(`sources?is_enabled=eq.true&health=neq.broken&or=(last_success_at.lt.${cutoff},last_success_at.is.null)&created_at=lt.${cutoff}&select=id,name`);
  for (const s of stale) await db.patch(`sources?id=eq.${s.id}`, { health: "broken" });
  // TODO(phase 2): re-discovery from homepage <link rel="alternate"> for broken sources.
  // TODO(phase 4): push "source broken: <name>" to the owner through the app's own alert pipeline.
  // TODO(phase 4): digest generation at each user's digest_hour.
}


async function enrichBackfill(env: Env): Promise<number> {
  const db = sb(env);
  const since = new Date(Date.now() - 48 * 3600 * 1000).toISOString();
  const rows = await db.get<{ id: string; title: string; excerpt: string | null }[]>(
    `articles?published_at=gt.${since}&select=id,title,excerpt,topics,regions&order=published_at.desc&limit=500`,
  );
  // 200/call keeps up with ~2-2.5k articles/day across 12 daily runs (100 ran a deficit
  // that aged out of the 48h window permanently unenriched). Still exactly one call.
  const thin = (rows as any[]).filter((r) => (r.topics ?? []).length <= 1).slice(0, 200);
  if (!thin.length) return 0;
  const meta = await enrichChunk(env, thin);   // exactly ONE Gemini call per invocation (quota: 20/day)
  let patched = 0;
  for (let i = 0; i < thin.length; i++) {
    const m = meta[i];
    if (!m.topics.length && !m.entities.length) continue;
    await db.patch(`articles?id=eq.${thin[i].id}`, {
      topics: [...new Set([...((thin[i] as any).topics ?? []), ...m.topics])],
      // Union: Gemini often returns [] regions; wholesale overwrite erased the ingest tag.
      entities: m.entities, regions: [...new Set([...((thin[i] as any).regions ?? []), ...(m.regions ?? [])])],
    }).catch(() => {});
    patched++;
  }
  return patched;
}


/// AI overview: ONE Gemini call/day writes a 2-3 sentence brief per topic (quota: 20/day).
async function generateBriefs(env: Env): Promise<number | string> {
  const db = sb(env);
  const today = new Date().toISOString().slice(0, 10);
  // Idempotent: the 09:20 retry cron (and manual reruns) must not burn quota on a done day.
  const existing = await db.get<unknown[]>(`briefs?brief_date=eq.${today}&select=topic&limit=1`).catch(() => []);
  if (existing.length) return "already-done";
  const topics = ["world", "business", "economics", "tech", "ai", "science", "sports", "crypto", "gaming", "entertainment", "space", "climate", "health", "travel"];
  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const rows = await db.get<{ title: string; topics: string[] }[]>(
    `articles?published_at=gt.${since}&select=title,topics&order=base_score.desc&limit=400`,
  );
  const byTopic: Record<string, string[]> = {};
  for (const r of rows) for (const tp of r.topics ?? []) {
    if (topics.includes(tp) && (byTopic[tp] ??= []).length < 12) byTopic[tp].push(r.title);
  }
  const withNews = topics.filter((tp) => (byTopic[tp] ?? []).length >= 3);
  if (!withNews.length) return 0;
  const prompt = `You write NewsFirst's daily topic briefs. For each topic below, write a tight 2-3 sentence overview of the day from its headlines: lead with the most important development, neutral tone, no hedging, no "headlines suggest". Return ONLY a JSON object mapping topic slug -> brief string.
${withNews.map((tp) => `## ${tp}\n${byTopic[tp].join("\n")}`).join("\n\n")}`;
  try {
    const call = (model: string) => fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${env.GEMINI_API_KEY}`,
      { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ contents: [{ parts: [{ text: prompt }] }], generationConfig: { responseMimeType: "application/json", temperature: 0.2 } }) },
    );
    // One run per day: ride out 429 RPM windows and 5xx load-shedding (the 2026-07-05
    // killer), then fall back to the bigger flash model — free-tier quotas are per-model.
    let r: Response | null = null;
    outer: for (const model of ["gemini-2.5-flash-lite", "gemini-2.5-flash"]) {
      r = await call(model);
      for (const wait of [10_000, 25_000]) {
        if (r.ok) break outer;
        if (r.status !== 429 && r.status < 500) break outer;   // hard error: no point retrying
        await sleep(wait);
        r = await call(model);
      }
      if (r.ok) break;
    }
    if (!r || !r.ok) throw new Error(`gemini ${r?.status} ${r ? (await r.text()).slice(0, 300) : ""}`);
    const j: any = await r.json();
    const map = JSON.parse(geminiText(j)) as Record<string, string>;
    const payload = Object.entries(map)
      .filter(([tp, c]) => withNews.includes(tp) && typeof c === "string" && c.length > 30)
      .map(([tp, c]) => ({ topic: tp, brief_date: today, content: c }));
    if (payload.length) await db.post("briefs?on_conflict=topic,brief_date", payload, "resolution=merge-duplicates,return=minimal");
    return payload.length;
  } catch (e) {
    // -1 with no trace hid a dead feature for a day; the log line IS the fix.
    console.error("briefs:", e instanceof Error ? e.message : e);
    return -1;
  }
}

// ---------- alerts (the product: match → claim → push) ----------
// claim_alerts() in Postgres does all matching/gating and INSERTS the alerts rows
// atomically (the insert is the claim); this side only fans out to APNs and records
// per-device outcomes. Delivery truth: delivered_at = APNs accepted (200) for ≥1 device.
const TOPIC_LABELS: Record<string, string> = {
  world: "World", business: "Business", economics: "Economics", tech: "Tech", ai: "AI",
  science: "Science", sports: "Sports", crypto: "Crypto", gaming: "Gaming",
  entertainment: "Entertainment", space: "Space", climate: "Climate", health: "Health", travel: "Travel",
};

interface ClaimedAlert {
  alert_id: string; user_id: string; article_id: string; topic: string; kind: string;
  title: string; excerpt: string | null; source_name: string; cluster_id: string | null;
  devices: { token: string; environment: string }[] | null;
}

async function alertsTick(env: Env): Promise<unknown> {
  if (!env.APNS_KEY_P8 || !env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_TOPIC) {
    console.error("alerts: APNS_* secrets missing — tick skipped");
    return "apns-not-configured";
  }
  const db = sb(env);
  const claimed = await db.postRows("rpc/claim_alerts", {}, "return=representation") as ClaimedAlert[];
  if (!claimed.length) return { claimed: 0 };

  let sent = 0, invalidated = 0;
  const failures: string[] = [];
  for (const a of claimed) {
    const label = TOPIC_LABELS[a.topic] ?? a.topic;
    const payload = {
      aps: {
        alert: {
          title: a.kind === "breaking" ? `Breaking · ${label}` : label,
          subtitle: a.source_name,
          body: a.title,
        },
        sound: "default",
        "thread-id": a.topic,
        "interruption-level": a.kind === "breaking" ? "time-sensitive" : "active",
        "mutable-content": 1,
      },
      alert_id: a.alert_id, article_id: a.article_id, topic: a.topic,
    };
    let accepted: string | null = null;
    for (const d of a.devices ?? []) {
      const r = await sendPush(env, d, payload, a.cluster_id);
      if (r.ok) { accepted = r.apnsId ?? "accepted"; sent++; }
      else if (r.status === 410 || r.reason === "BadDeviceToken" || r.reason === "Unregistered" || r.reason === "DeviceTokenNotForTopic") {
        // Dead token: mark, don't retry forever. Rows are pruned later, never silently deleted.
        await db.patch(`devices?apns_token=eq.${encodeURIComponent(d.token)}`, { is_valid: false }).catch(() => {});
        invalidated++;
      } else {
        failures.push(`${r.status}:${r.reason || "?"}`);
        console.error(`alerts: apns ${r.status} ${r.reason} (alert ${a.alert_id})`);
      }
    }
    if (accepted) {
      await db.patch(`alerts?id=eq.${a.alert_id}`,
        { apns_id: accepted, delivered_at: new Date().toISOString() }).catch(() => {});
    }
  }
  return { claimed: claimed.length, sent, invalidated, failures: failures.slice(0, 5) };
}

/// Daily briefing push (on by default): one digest notification per user per day,
/// title previews their top stories, payload carries brief:"1" so the client
/// auto-plays the spoken briefing. Opt-out = notification_settings.daily_brief=false.
async function briefPush(env: Env): Promise<unknown> {
  if (!env.APNS_KEY_P8) return "apns-not-configured";
  const db = sb(env);
  const today = new Date().toISOString().slice(0, 10);
  const briefs = await db.get<{ topic: string }[]>(`briefs?brief_date=eq.${today}&select=topic&limit=1`);
  if (!briefs.length) return "no-briefs-yet";   // 09:45 sweep retries after the briefs retry cron

  const devices = await db.get<{ user_id: string; apns_token: string; environment: string }[]>(
    "devices?is_valid=eq.true&select=user_id,apns_token,environment");
  if (!devices.length) return { users: 0 };
  const byUser = new Map<string, { token: string; environment: string }[]>();
  for (const d of devices) (byUser.get(d.user_id) ?? byUser.set(d.user_id, []).get(d.user_id)!)
    .push({ token: d.apns_token, environment: d.environment });

  const optedOut = new Set((await db.get<{ user_id: string }[]>(
    "notification_settings?daily_brief=eq.false&select=user_id")).map((r) => r.user_id));
  const sentToday = new Set((await db.get<{ user_id: string }[]>(
    `alerts?kind=eq.digest&sent_at=gte.${today}T00:00:00Z&select=user_id`)).map((r) => r.user_id));

  // Preview pool: today's front page. Personalized per user by their subscribed topics.
  const pool = await db.get<{ title: string; topics: string[] }[]>(
    "feed?select=title,topics&order=score.desc,published_at.desc&limit=40");
  const subs = await db.get<{ user_id: string; topic: string; kind: string }[]>(
    "topic_subscriptions?select=user_id,topic,kind");
  const userTopics = new Map<string, Set<string>>();
  for (const s of subs.filter((s) => s.kind === "preset")) {
    (userTopics.get(s.user_id) ?? userTopics.set(s.user_id, new Set()).get(s.user_id)!).add(s.topic);
  }

  let sent = 0, skipped = 0;
  for (const [uid, tokens] of byUser) {
    if (optedOut.has(uid) || sentToday.has(uid)) { skipped++; continue; }
    const mine = userTopics.get(uid);
    const picks = pool.filter((a) => !mine?.size || a.topics?.some((t) => mine.has(t))).slice(0, 3);
    const fallback = picks.length ? picks : pool.slice(0, 3);
    if (!fallback.length) continue;
    const trim = (s: string, n: number) => s.length > n ? s.slice(0, n - 1).trimEnd() + "…" : s;
    const payloadAlert = {
      title: `Your briefing · ${trim(fallback[0].title, 60)}`,
      body: fallback.slice(1).map((a) => trim(a.title, 70)).join(" — ") || "Tap to listen to today's news.",
    };
    const claimed = await db.postRows("alerts",
      [{ user_id: uid, topic: "brief", kind: "digest" }], "return=representation") as { id: string }[];
    const alertId = claimed[0]?.id;
    if (!alertId) continue;
    const payload = {
      aps: { alert: payloadAlert, sound: "default", "thread-id": "daily-brief" },
      brief: "1", alert_id: alertId,
    };
    let accepted: string | null = null;
    for (const d of tokens) {
      const r = await sendPush(env, d, payload, `brief-${today}`);
      if (r.ok) { accepted = r.apnsId ?? "accepted"; sent++; }
      else if (r.status === 410 || r.reason === "BadDeviceToken" || r.reason === "Unregistered") {
        await db.patch(`devices?apns_token=eq.${encodeURIComponent(d.token)}`, { is_valid: false }).catch(() => {});
      } else console.error(`brief_push: apns ${r.status} ${r.reason}`);
    }
    if (accepted) {
      await db.patch(`alerts?id=eq.${alertId}`,
        { apns_id: accepted, delivered_at: new Date().toISOString() }).catch(() => {});
    }
  }
  return { users: byUser.size, sent, skipped };
}

Deno.serve(async (req: Request) => {
  const env: Env = {
    SUPABASE_URL: Deno.env.get("SUPABASE_URL")!,
    SUPABASE_SERVICE_KEY: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    GEMINI_API_KEY: Deno.env.get("GEMINI_API_KEY") ?? "",
    APNS_KEY_P8: Deno.env.get("APNS_KEY_P8") ?? "",
    APNS_KEY_ID: Deno.env.get("APNS_KEY_ID") ?? "",
    APNS_TEAM_ID: Deno.env.get("APNS_TEAM_ID") ?? "",
    APNS_TOPIC: Deno.env.get("APNS_TOPIC") ?? "",
  };
  // Only the service role may trigger ingestion (verify_jwt alone would admit the public anon key).
  // The gateway has already verified the JWT signature; here we only need the role claim.
  const bearer = req.headers.get("Authorization")?.replace("Bearer ", "") ?? "";
  const isServiceRole = bearer === env.SUPABASE_SERVICE_KEY || (() => {
    try { return JSON.parse(atob(bearer.split(".")[1])).role === "service_role"; }
    catch { return false; }
  })();
  if (!isServiceRole) {
    return new Response("forbidden", { status: 403 });
  }
  const task = new URL(req.url).searchParams.get("task") ?? "ingest";
  let detail: unknown = null;
  if (task === "watchdog") await healthWatchdog(env);
  else if (task === "enrich_backfill") detail = await enrichBackfill(env);
  else if (task === "briefs") detail = await generateBriefs(env);
  else if (task === "embed") {
    const n = Math.max(1, Math.min(100, Number(new URL(req.url).searchParams.get("n")) || 12));
    detail = await embedNewArticles(env, n);
  }
  else if (task === "alerts") detail = await alertsTick(env);
  else if (task === "brief_push") detail = await briefPush(env);
  else await ingestTick(env);
  return new Response(JSON.stringify({ ok: true, task, detail }), { headers: { "Content-Type": "application/json" } });
});
