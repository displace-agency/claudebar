# Validation

RelayBar is tested at three levels:

- **Offline fixtures:** cumulative Codex records, active/archive deduplication, resumed sessions, cache accounting, partial trailing lines, calendar ranges, quota window parsing, countdown boundaries, malformed responses, HTTP errors, timeout handling, rate-limit backoff, and stale-reading recovery.
- **Opt-in live checks:** fetch each configured subscription's weekly usage and reset time. These checks require an existing login and print only sanitized quota summaries.
- **Offscreen native rendering:** light, dark, and unavailable states. OCR checks confirm the actual provider names, percentages, and countdowns are present. This catches empty renders that image-dimension checks miss.

The initial RelayBar release passed the offline suite, both live quota checks, and visual review of the rendered interface. Apple Silicon and Intel binaries are built together. Native installation and launch were also checked on the development Mac.

## Running tests

```bash
swift test
RELAYBAR_LIVE_USAGE_TEST=1 swift test --filter SubscriptionUsageTests
RELAYBAR_PREVIEW_DIR=/tmp/relaybar-preview swift test --filter PreviewTests
```

The default suite skips network and screenshot-export checks. An unavailable provider can legitimately fail an opt-in live check without affecting offline tests.

## Public screenshots

The `relaybar-*.png` images in `docs/screenshots/` render the native interface with live quota readings and local aggregate token data. They contain no account identifiers, conversation text, project names, or client details. Development fixture images are separate and are not used as product evidence.

## Practical limits

- Private provider usage endpoints can change.
- Expired or revoked login is reported, not repaired by rotating credentials.
- Codex quota does not cover every ChatGPT model or API billing.
- Local history only covers files available on the current Mac.
- Large histories require an initial scan; subsequent unchanged scans use memory caches.
- The build is not Apple-notarized. Installation instructions explain the first-launch step.
- Claude's legacy API-equivalent costs are estimates; Codex costs are hidden.
