# Security Policy

## Supported versions

Only the latest release receives fixes.

| Version | Supported |
|---|---|
| 0.4.x | ✅ |
| < 0.4 | ❌ |

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private reporting:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Describe the issue, the version, and the steps to reproduce.

You can expect an initial reply within a week. Once a fix is released the
advisory is published with credit unless you ask to stay anonymous.

## Scope and threat model

Tugi is an offline media tool. There is no server, no account and no telemetry.
Its interesting failure modes are therefore local:

- **Malicious media files.** Every operation is fed to ffmpeg, which parses
  untrusted containers. A crafted file could crash the process; ffmpeg itself is
  the parser under test, and keeping it current is the mitigation.
- **The Scramble feature is obfuscation, not encryption.** It is a reversible
  permutation plus an RGB keystream derived from the password via FNV-1a. That
  is enough to stop casual sharing, not a determined attacker, and it gives no
  authentication. Do not use it for confidential data.
- **File access.** The app reads only the files the user picks and writes only to
  the gallery, the system save dialog, or its own cache. It declares no
  `INTERNET` permission.
- **Tokens and credentials.** A password typed into Scramble is used in memory and
  never stored or logged.

## Out of scope

- Crashes caused by a deliberately corrupt file where ffmpeg aborts cleanly and
  the app reports an error.
- Anything requiring a rooted device or physical access to an unlocked phone.
- The security of the `ffmpeg-kit` binary itself; report those upstream.
