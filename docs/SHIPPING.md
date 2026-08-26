# Getting the app onto a phone without a Mac

Xcode only runs on macOS, so a Mac has to compile this somewhere. It doesn't
have to be *your* Mac: GitHub Actions rents one per run, and TestFlight
installs the result on your phone with no computer involved at either end.

## If you shipped airtistic, this is the same shape

`airtistic` is an Expo app, so `eas build` sent it to Expo's cloud macOS
machines and you installed from a link. Same idea here, different builder:
EAS Build only handles React Native/Expo projects, and this app is a native
Xcode project, so GitHub Actions provides the Mac instead.

Two things carry over and save you work:

- **You already have the paid Apple Developer Program membership.** EAS
  couldn't have created those certificates without it.
- **Your iPhone is already registered with Apple**, from `eas device:create`.
  That matters only for the ad-hoc route described at the bottom; TestFlight
  doesn't care about registered devices.

One thing that probably doesn't carry over: EAS stores Apple credentials on
Expo's servers, so you likely don't have the `.p8` file locally even if a key
was created. Apple only lets each key be downloaded once. Just create a second
API key in step 3 — there's no limit worth worrying about, and it doesn't
disturb the EAS one.

Two workflows do the work:

| Workflow | What it's for | Needs an Apple account |
|---|---|---|
| `.github/workflows/build.yml` | Does it compile? Runs on every push. | No |
| `.github/workflows/testflight.yml` | Sign and ship to your phone. Manual. | Yes, paid |

Start with the first one. There is no point setting up signing for code that
doesn't build yet.

---

## Stage 1 — get it compiling

Nothing to configure. Push to the branch and open the **Actions** tab.

When a build fails, the run's summary page lists the compiler errors directly —
copy them out and they're enough to work from. The full log is attached as an
artifact if more context is needed.

A run takes roughly 5–10 minutes. **This repository is private**, and GitHub
bills macOS runner minutes at **10× the rate of Linux**, so the free 2,000
minutes a month works out to about 200 macOS minutes — call it 25 builds. Ways
to stretch that:

- The vendored Python runtime is cached between runs, which saves a few minutes
  each time. Only the first run pays for the download.
- Push batches of fixes rather than one at a time.
- Making the repository public removes the limit entirely — Actions is free and
  unmetered for public repos. Consider whether you want the code public first.
- Or add a payment method: extra minutes are cheap for this volume.

---

## Stage 2 — one-time Apple setup

You need the **paid** Apple Developer Program membership ($99/year). A free
Apple ID cannot use TestFlight, and every other install route (Apple
Configurator, sideloading tools) needs a computer.

### 1. Register the bundle ID

[developer.apple.com](https://developer.apple.com/account) → **Certificates,
Identifiers & Profiles** → **Identifiers** → **+** → App IDs → App.

Give it a description and an explicit bundle ID such as
`com.brandonbell.ytdlphub`. Leave every capability unticked — this app uses
none of them. Photos access needs only an Info.plist string, which is already
in the project.

### 2. Create the app record

[App Store Connect](https://appstoreconnect.apple.com) → **Apps** → **+** →
**New App**.

- Platform: iOS
- Name: anything unique across the App Store — `YTDLP Hub` may be taken, so
  add a suffix. Only you will see it.
- Bundle ID: the one from step 1
- SKU: any string, e.g. `ytdlphub`

You never have to submit this for review. It exists so TestFlight has
somewhere to put builds.

### 3. Create an App Store Connect API key

App Store Connect → **Users and Access** → **Integrations** → **App Store
Connect API** → **+**.

- Name: `GitHub Actions`
- Access: **App Manager**

Download the `.p8` file. **Apple lets you download it exactly once.** Note the
**Key ID** next to it and the **Issuer ID** shown at the top of the page.

### 4. Find your Team ID

App Store Connect → **Membership details**. It's a 10-character string like
`A1B2C3D4E5`.

### 5. Add the secrets to GitHub

Repository → **Settings** → **Secrets and variables** → **Actions** → **New
repository secret**.

That page has **two** fields, and the large text box is the second one:

- **Name** — a small input at the top. Type the name exactly as written below;
  it is case-sensitive and the workflow looks for these literal strings.
- **Secret** — the large box. The raw value only: no quotes, no `NAME=` prefix,
  no JSON.

Fill both, click **Add secret**, then click **New repository secret** again for
the next one. These are five separate secrets, not one combined value.

| Name | Value | Shape |
|---|---|---|
| `APPSTORE_ISSUER_ID` | Issuer ID from step 3 | `69a6de70-1234-47e3-e053-5b8c7c11a4d1` |
| `APPSTORE_KEY_ID` | Key ID from step 3 | `ABC123DEFG` |
| `APPSTORE_PRIVATE_KEY` | The whole `.p8` file | multi-line PEM, below |
| `APPLE_TEAM_ID` | Team ID from step 4 | `A1B2C3D4E5` |
| `APP_BUNDLE_ID` | Bundle ID from step 1 | `com.brandonbell.ytdlphub` |

The Key ID is the short one beside the key in the list. The Issuer ID is the
long UUID printed once above the table — they are easy to swap by mistake.

For `APPSTORE_PRIVATE_KEY`, open `AuthKey_XXXXXXXXXX.p8` in a text editor and
paste all of it, first and last lines included:

```
-----BEGIN PRIVATE KEY-----
MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg...
-----END PRIVATE KEY-----
```

Multi-line values are fine. If nothing on your machine will open a `.p8`,
rename it to `.txt`, or `cat` it inside a Codespace.

A saved secret can never be read back, only overwritten. If you are unsure a
value is right, add it again under the same name to replace it.

The bundle ID is passed to `xcodebuild` on the command line, so there is
nothing to edit in the project.

### 6. Add yourself as an internal tester

App Store Connect → your app → **TestFlight** → **Internal Testing** → create a
group, add your own Apple ID.

Internal testing does not go through Beta App Review — builds become
installable as soon as Apple finishes processing them, usually a few minutes.

---

## Stage 3 — ship it

GitHub → **Actions** → **TestFlight** → **Run workflow**.

The first run takes longer than later ones because it creates the signing
certificate and provisioning profile on Apple's side. When it finishes, Apple
processes the build and emails you.

On the phone: install **TestFlight** from the App Store, sign in with the same
Apple ID, and the build appears. Tap **Install**.

Each build is good for **90 days**, after which you re-run the workflow. The
build number comes from the workflow run number, so it always increments.

---

## Notes

**You're uploading to Apple's servers.** Internal TestFlight builds aren't
reviewed, but the build does sit in App Store Connect under your developer
account. Worth knowing given what the app does. It doesn't get scanned or
scrutinised the way a submission would, but it isn't invisible either.

**The alternative that avoids Apple's servers** is ad-hoc distribution: sign
for specific registered devices, host the `.ipa` and a manifest on HTTPS, and
install by tapping an `itms-services://` link in Safari. Nothing is uploaded to
Apple. The usual blocker is getting your iPhone's UDID without a computer —
but `eas device:create` already registered it for airtistic, so it is sitting
in your developer account. The remaining work is somewhere HTTPS to host the
`.ipa` and manifest. Worth doing if you would rather this build never touched
App Store Connect; otherwise TestFlight is fewer moving parts.

**If you'd rather have a real Xcode** — for breakpoints, the view debugger,
Instruments — rent one by the hour or month (MacinCloud, MacStadium, Scaleway
all offer Apple silicon). Worth it if you plan to do sustained work on this;
overkill for getting a build onto your phone.
