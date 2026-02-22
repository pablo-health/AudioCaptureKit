# Security Policy

## Supported Versions

| Platform | Version | Supported |
|----------|---------|-----------|
| macOS (Swift) | latest main | ✅ |
| Windows (Rust) | latest main | ✅ |

## Reporting a Vulnerability

If you discover a security vulnerability in AudioCaptureKit, **please do not open a public issue.**

Instead, please report it through GitHub's private vulnerability reporting:

1. Go to the **Security** tab of this repository
2. Click **"Report a vulnerability"**
3. Fill in the details and submit

We will acknowledge receipt within **48 hours** and aim to provide a fix or mitigation plan within **7 business days**, depending on severity.

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Affected platform(s) and version(s)
- Potential impact (e.g., data exposure, privilege escalation)

## Security Practices

This project handles sensitive audio data and follows these security practices:

- **Encryption**: All captured audio is encrypted with AES-256-GCM before reaching disk. No plaintext audio is stored.
- **HIPAA-aware logging**: `print()` is forbidden in production code; all logging uses `os.log` / `Logger` with appropriate privacy levels.
- **Dependency scanning**: Automated via Trivy, cargo audit, cargo deny, npm audit, and Dependabot.
- **Static analysis**: SwiftLint (strict mode), Clippy (deny warnings), CodeQL, and Trivy misconfiguration scanning.
- **License compliance**: GPL/AGPL dependencies are denied via cargo-deny and GitHub dependency review.
- **CI enforcement**: All security checks run on every PR and on a weekly schedule.
