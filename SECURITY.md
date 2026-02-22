# Security Policy

## Supported Versions

| Platform | Version | Supported |
|----------|---------|-----------|
| macOS (Swift) | latest main | ✅ |
| Windows (Rust) | latest main | ✅ |

## Reporting a Vulnerability

If you discover a security vulnerability in AudioCaptureKit, **please do not open a public issue.**

Instead, please report it through [GitHub's private vulnerability reporting](https://github.com/pablo-health/AudioCaptureKit/security/advisories/new):

1. Go to the [Security Advisories](https://github.com/pablo-health/AudioCaptureKit/security/advisories) page
2. Click **"Report a vulnerability"**
3. Fill in the details and submit

If you are unable to use GitHub's reporting, you may email [security@lll-solutions.com](mailto:security@lll-solutions.com) with the subject line "AudioCaptureKit Vulnerability Disclosure".

### Response Timeline

- A maintainer will **acknowledge** the report within **3 business days**
- A detailed response with next steps will follow within **7 business days**
- A fix or mitigation will be developed within **90 days** of the initial report, depending on severity and complexity

### Disclosure Policy

We follow a [coordinated vulnerability disclosure](https://en.wikipedia.org/wiki/Coordinated_vulnerability_disclosure) process:

- Reporters are asked to keep vulnerability details confidential until a fix is released
- We will coordinate a disclosure timeline with the reporter
- Security advisories will be published via [GitHub Security Advisories](https://github.com/pablo-health/AudioCaptureKit/security/advisories) once a fix is available
- Credit will be given to reporters unless they prefer to remain anonymous

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Affected platform(s) and version(s)
- Potential impact (e.g., data exposure, privilege escalation)
- Any suggested fix or mitigation (optional)

## Security Practices

This project handles sensitive audio data and follows these security practices:

- **Encryption**: All captured audio is encrypted with AES-256-GCM before reaching disk. No plaintext audio is stored.
- **HIPAA-aware logging**: `print()` is forbidden in production code; all logging uses `os.log` / `Logger` with appropriate privacy levels.
- **Dependency scanning**: Automated via [Trivy](https://github.com/aquasecurity/trivy), cargo audit, cargo deny, npm audit, and [Dependabot](https://github.com/pablo-health/AudioCaptureKit/security/dependabot).
- **Static analysis**: SwiftLint (strict mode), Clippy (deny warnings), [CodeQL](https://github.com/pablo-health/AudioCaptureKit/security/code-scanning), and Trivy misconfiguration scanning.
- **CI enforcement**: All security checks run on every PR and on a weekly schedule.
