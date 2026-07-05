# Tom's Setup Guide — the human-in-the-loop steps

Everything below is stuff only you (the Apple Developer account owner) can do. Total hands-on time: **~1 hour**, in five chunks. Once each chunk is done, Claude takes over and wires it in — the schema, UI stubs, and edge functions are already built and waiting.

**Do them in this order.** Chunk 1 unblocks the actual product (alerts). Chunks 2–3 unblock sign-in. Chunk 4 unblocks TestFlight. Chunk 5 (RevenueCat) can wait until the paywall phase.

---

## Chunk 1 — Apple Developer portal: Push Notifications (~20 min) ⭐ THE PRODUCT

Push alerts are the core of v3. The alert matcher, `topic_subscriptions.notify_level`, `alerts` table, and `devices` table are all built server-side — this is the only missing piece.

1. Go to **developer.apple.com/account** and sign in with the Apple ID that owns NewsFirst (the one you use for App Store Connect — tshawstewart@gmail.com).
2. Open **Certificates, Identifiers & Profiles → Identifiers**.
3. Click the App ID **`com.ant2555.newsfirst`** (the existing v2 bundle — we're keeping it).
4. In the Capabilities list, tick **Push Notifications**. Save.
   - While you're on this screen, also tick **Sign In with Apple** (that's Chunk 2, saves a second visit). Save again.
5. Go to **Keys** (left sidebar) → **+** to create a new key.
   - Name: `NewsFirst APNs`
   - Tick **Apple Push Notifications service (APNs)**.
   - Continue → Register → **Download the `.p8` file**. ⚠️ You can only download it once.
6. Note down two values shown on that page:
   - **Key ID** (10 characters, e.g. `AB12CD34EF`)
   - **Team ID** (top-right of the portal, or under Membership — also 10 characters)
7. Hand it to Claude: put the `.p8` file in **`Claude workspace/secrets/`** (create the folder; it's outside the repo) and paste the Key ID + Team ID in chat.

**What Claude does next:** stores the key as a Supabase Vault/function secret, builds the alert-matcher edge function + APNs sender, adds the Notification Service Extension and Time-Sensitive entitlement in Xcode (no portal step needed for those), and the render-from-payload notification open.

---

## Chunk 2 — Sign in with Apple (~10 min)

Prereq: the **Sign In with Apple** capability ticked in Chunk 1 step 4.

1. Open the Supabase dashboard: **supabase.com/dashboard/project/sbqdvtzsezxupxxbmjsb**
2. Go to **Authentication → Sign In / Providers → Apple**.
3. Toggle it **on**.
4. In the **Client IDs** field, enter the bundle id: `com.ant2555.newsfirst`
   - That's all — the native iOS flow doesn't need the Secret Key / Services ID fields (those are only for web OAuth). Leave them blank.
5. Save.

**What Claude does next:** replaces the stubbed "Continue with Apple" button with `ASAuthorizationController` → `signInWithIdToken`, verified on device/TestFlight (Sign in with Apple doesn't fully work on simulator).

---

## Chunk 3 — Google sign-in (~15 min)

1. Go to **console.cloud.google.com** (any Google account — suggest getyournewsfirst@gmail.com so it lives with the product).
2. Create a project (top bar → project picker → New Project): name it `NewsFirst`.
3. **APIs & Services → OAuth consent screen** (now under "Google Auth Platform"):
   - User type: **External** → Create.
   - App name `NewsFirst`, support email = your Gmail, developer contact = same. Save through the remaining screens (no scopes needed beyond default).
   - Publish the app (Publishing status → **In production**) so sign-in isn't limited to test users.
4. **APIs & Services → Credentials → + Create credentials → OAuth client ID**:
   - Application type: **iOS**
   - Bundle ID: `com.ant2555.newsfirst`
   - Create → note the **Client ID** (`xxxx.apps.googleusercontent.com`) and the **iOS URL scheme** (the reversed client ID shown on the same page).
5. Create a **second** OAuth client ID, type **Web application**, name `NewsFirst Supabase` (no redirect URIs needed for the native flow). Note its Client ID too. (Supabase validates the token audience against this.)
6. In the Supabase dashboard → **Authentication → Sign In / Providers → Google**:
   - Toggle **on**.
   - **Client IDs / Authorized Client IDs**: paste **both** client IDs (iOS one and Web one), comma-separated.
   - Skip the client secret (native flow only). Save.
7. Paste in chat for Claude: the iOS Client ID + reversed URL scheme, and the Web client ID.

**What Claude does next:** adds the GoogleSignIn SDK, the URL scheme to Info.plist, and wires the "Continue with Google" button via `signInWithIdToken`.

---

## Chunk 4 — TestFlight / App Store Connect (~10 min at the Mac)

Two parts: let Xcode sign builds, and (optional but recommended) give Claude an upload key.

**A. Sign into Xcode (required):**
1. On this Mac: **Xcode → Settings → Accounts → +** → sign in with your Apple ID.
2. That's it — automatic signing can then provision `com.ant2555.newsfirst` and the notification extension.

**B. App Store Connect API key (lets Claude upload builds unattended):**
1. **appstoreconnect.apple.com → Users and Access → Integrations → App Store Connect API → Team Keys → +**
2. Name `newsfirst-ci`, role **App Manager** → Generate.
3. Download the **.p8** (again, one-shot download) into `Claude workspace/secrets/`, and paste the **Issuer ID** and **Key ID** in chat.

**C. Real-device feel check (whenever a build is ready):**
1. On your iPhone: **Settings → Privacy & Security → Developer Mode → on** (requires restart).
2. Plug into the Mac, tap **Trust**. Claude can then install builds directly for the <1s launch-time verification.

**What Claude does next:** archives v2.0.0 (release config), uploads to TestFlight, and re-verifies the launch-time budget on device. Reminder: v3 ships as an **update** to the existing listing — and the March rejection (5.1.1, forced registration) is already fixed in v3: sign-in is an optional sheet, news is readable without an account.

---

## Chunk 5 — RevenueCat (~20 min, can wait until paywall phase)

1. **App Store Connect** first: open the NewsFirst app → **Monetization → Subscriptions**:
   - Create a Subscription Group `NewsFirst Pro`.
   - Inside it, create a subscription: reference name `Pro Annual`, product ID **`newsfirst_pro_annual`**, duration 1 year, price **£29.99**. Add the localized display name/description. (It can sit in "Missing Metadata" until first submission — fine.)
2. Still in App Store Connect: **Users and Access → Integrations → In-App Purchase** → generate an **In-App Purchase key**, download the .p8 → `Claude workspace/secrets/`, note the Key ID + Issuer ID.
3. **app.revenuecat.com** → sign up (free) → New project `NewsFirst` → add an **App Store** app, bundle id `com.ant2555.newsfirst`, and upload/paste the In-App Purchase key from step 2.
4. In RevenueCat: create an **Entitlement** `pro`, attach the `newsfirst_pro_annual` product, and copy the app's **public SDK key** (starts `appl_`) → paste in chat.

**What Claude does next:** adds the RevenueCat SDK, paywall UI gated on the `pro` entitlement (free tier = 3 custom topics, already enforced by the DB trigger), and purchase/restore flows.

---

## Quick reference — what Claude is waiting on

| # | You provide | Unblocks |
|---|---|---|
| 1 | APNs .p8 + Key ID + Team ID; Push capability ticked | Alerts/push — the product (Phase 4) |
| 2 | Sign In with Apple capability ticked + Supabase toggle | Apple sign-in button |
| 3 | Google OAuth client IDs + Supabase toggle | Google sign-in button |
| 4 | Xcode account sign-in (+ optional ASC API key) | TestFlight build, device testing |
| 5 | RevenueCat key + IAP product | Paywall (Phase 5) |

Drop-off convention: one-shot key files (.p8) go in **`Claude workspace/secrets/`** (outside the git repo, never committed); IDs (Key ID, Team ID, client IDs, Issuer ID) can just be pasted in chat.
