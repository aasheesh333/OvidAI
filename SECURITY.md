# Security Policy

## Reporting a vulnerability

Do not open a public issue for security problems. Report privately via
GitHub's "Report a vulnerability" (Security → Advisories) on this
repository, or email the maintainer listed in `CODEOWNERS`.

Include: affected version/commit, reproduction steps, impact, and any
suggested fix. We aim to acknowledge within 72 hours.

## Scope

In scope: the Android app (`android/`), the Dart runtime (`lib/`), the
plugin/MCP/hook/skill runtime, and the CI workflows.

Out of scope: vulnerabilities in third-party services, and issues that
require a rooted device with the app's own keystore already extracted.

## Handling secrets

This repository never contains signing keys, `google-services.json`, or
API keys. They are injected at build time from CI secrets. If you find a
committed secret, report it immediately; it will be rotated and purged.

## Supported versions

Only the latest commit on the default branch is supported.
