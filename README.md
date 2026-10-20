# Promise Tracker

Never forget what you promised. A private, on-device iPhone app that turns the things you say you’ll do into reviewable promises with reminders. See [`PRD`](PRD) for the full specification.

## Layout

| Path | What it is |
|------|------------|
| `Sources/PromiseCore/` | Platform-independent domain logic (Foundation only). Builds and tests on macOS, iOS and Linux. |
| `Tests/PromiseCoreTests/` | Unit tests for the core (dates, extraction, safety rules, reminders, persistence, use cases). |
| `App/PromiseTracker/` | SwiftUI iOS app: screens, design system, and Apple-only adapters. |
| `project.yml` | [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec for the Xcode project. |
| `.github/workflows/ci.yml` | Runs core tests on Linux and macOS, and builds the iOS app with Xcode 26. |

### Core (`PromiseCore`)

- **Entities** – `Commitment`, `Person`, `ActivityEvent` (append-only history), `ReminderRule`, settings. Deadlines keep the wall-clock value (`dueLocal`), precision (`day`, `datetime`, `approximate`, `event-linked`…), time zone and the verbatim phrase separately from the absolute `dueAt`.
- **DateInterpretation** – deterministic resolver for phrases like “by Friday at four”, “next Thursday”, “this week”, “end of day”, “in 2 hours”, “24/10”. It handles DST gaps and overlaps, regional week starts, locale date order and leap years. It flags anything ambiguous (am/pm, “next Thursday”, past dates) so you have to confirm it. A partial Polish lexicon is included to prove the design; the app ships English.
- **Extraction** – the extraction contract (mirrors the Foundation Models schema) and a rule-based fallback extractor. The fallback recognizes direction (“Sarah promised me”), negation, hypotheticals, several promises in one sentence, and dependencies (“once Legal approves it”).
- **Validation** – grounding checks for every extractor’s output: recipients and deadlines must appear in your words, fabricated items are dropped, and priority needs evidence. Also person matching (never auto-merges).
- **ReminderPolicy** – reminder planning (day-before, at-due, overdue nudge, waiting check-ins, period check-ins, snooze, digest) plus reconciliation against the OS queue within the 64-notification limit.
- **Persistence** – transactional JSON store. Writes are atomic and encrypted at rest on iOS, and a failed save leaves no partial state. It has schema migrations, never overwrites files from newer versions, sets aside unreadable files instead of deleting them, and supports JSON/CSV export.
- **UseCases** – `PromiseService` (save with idempotency tokens, edit, reschedule with history, complete/reopen, waiting, snooze, duplicate, delete, people merge), classifier and smart filters, search, digest, stats, free/Pro entitlements, follow-up templates.

### App (`App/PromiseTracker`)

- **Design** – the warm cream / serif / black-pill design from the mockups, with dark-mode tokens, Dynamic Type and VoiceOver labels.
- **AI** – `FoundationModelExtractor` uses `@Generable` guided generation on iOS 26 when `SystemLanguageModel` reports it is available for your locale. Otherwise the rule-based extractor is used and the reason is shown to you. There are no cloud AI calls.
- **Speech** – `SFSpeechRecognizer` dictation, on-device when supported. It records only while the capture screen is open and keeps partial text if recording is interrupted.
- **Notifications** – local reminders with Mark Done / Snooze / Open actions, reconciled on launch, on foreground and after every change.
- **App Intents** – Add Promise (saves directly, or continues in the app for review), Show Promises (incl. “What do I owe Anna in Promise Tracker”), Mark Complete (idempotent), Snooze, Open Capture, plus App Shortcuts.
- **StoreKit 2** – monthly/yearly Pro. Entitlement comes from verified transactions. Closing, editing and exporting are never locked.

## Build and run

Requirements: Xcode 26 (for the Foundation Models SDK; the app still runs on iOS 17+ devices without it) and XcodeGen.

```sh
brew install xcodegen
xcodegen generate
open PromiseTracker.xcodeproj
```

Set your Development Team in the project (or `DEVELOPMENT_TEAM` in `project.yml`) to run on a device. The scheme uses `App/PromiseTracker/Resources/Products.storekit` for local StoreKit testing.

Core tests run anywhere Swift runs:

```sh
swift test
```

## Before release

- Fill in `AppConfig` in `Features/Settings/SettingsView.swift` (support URL, privacy policy, App Store link).
- Create the two subscription products in App Store Connect with the IDs in `StoreManager`.
- Change the bundle identifiers (`com.jabol183.*`) if needed.
- Run the on-device checks the PRD requires: Siri phrases, speech, notifications, Foundation Models on a supported iPhone, and an unsupported or “AI off” device. These can’t be verified in CI.
- Build the 250-scenario AI evaluation corpus (PRD §8.6) and run it against the on-device model.

## Known MVP limits

- iCloud sync, widgets, Contacts linking and Reminders export are P1 and not built yet. Settings › Sync says “This iPhone only”.
- The store is a single JSON file. That is fine at MVP scale (thousands of records); revisit if it grows much larger.
- English only at launch. Polish date parsing exists in the core but isn’t exposed.
