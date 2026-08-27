# Security policy

Kammel is an SSH client. It holds passwords and private keys, pins host keys, and
opens tunnels through the device. A bug in any of those is a real risk to the
people using it, so security reports get priority over everything else.

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub's private reporting:

→ [Report a vulnerability](https://github.com/Jhongdlp/Kammel_ssh/security/advisories/new)

If that is not available to you, that is reason enough to open an issue saying
only *"I have a security report, how do I reach you privately?"* — with no
details — and you will get a contact address.

Please include what you can: the version, the platform, and the smallest set of
steps that shows the problem. A proof of concept helps, but a clear description
is already enough to start.

*Puedes escribir en español.*

## What is in scope

Anything that could expose a credential or let a connection be impersonated:

- `SecureStore` — where passwords and private keys are kept (Keystore-backed on
  Android, libsecret on Linux).
- Host key verification and the `known_hosts` store: a changed key that fails to
  block, a fingerprint that renders wrong, a way to get a key trusted silently.
- Port forwarding: a tunnel reachable beyond what the user asked for, or an
  `exposeToLan` / idle-timeout control that does not do what it says.
- Backup and restore: the allow-list is enforced in both directions, so a
  crafted backup file writing arbitrary preferences would be a vulnerability.
- Git command construction, which builds argument lists and quotes every
  argument — an injection through a branch name, path or commit message counts.

## What is not

- Anything requiring a device that is already unlocked and compromised.
- The vendored dependencies under `third_party/` when the bug is upstream's —
  report those upstream too, but tell us so we can patch the vendored copy.
- Backups exported *with secrets included*: that file is plaintext by design and
  the toggle says so in words.

## Response

This is a small project maintained in spare time. You will get a first reply
within a week. If a fix ships, you get credit in the release notes unless you
would rather not.
