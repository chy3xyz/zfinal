# Security Policy

## Supported Versions

Use this section to tell people about which versions of your project are
currently being supported with security updates.

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a Vulnerability

We take the security of ZFinal seriously. If you discover a security vulnerability, please follow these steps:

1.  **Do NOT open a public issue.** Publicly disclosing a vulnerability can put the entire community at risk.
2.  Please report vulnerabilities privately via [GitHub Security Advisories](https://github.com/chy3xyz/zfinal/security/advisories/new).
3.  Include steps to reproduce the issue, if possible.
4.  We will acknowledge your email within 48 hours.
5.  We will investigate the issue and keep you updated on our progress.
6.  Once the issue is resolved, we will release a patch and publish a security advisory.

## Security Best Practices for ZFinal Users

*   **Input Validation**: Always use the built-in `Validator` to sanitize and validate user input.
*   **SQL Injection**: Use the Active Record ORM or parameterized queries (`SqlTemplate`) to prevent SQL injection attacks. Do not concatenate strings directly into SQL queries.
*   **XSS Protection**: When rendering HTML, ensure that user-generated content is properly escaped. The HTMX template engine provides basic protection, but be cautious when using `raw` output.
*   **CSRF Protection**: Implement CSRF tokens for state-changing requests (POST, PUT, DELETE).
*   **Dependencies**: Keep your Zig version and ZFinal dependencies up to date.

Thank you for helping keep ZFinal safe!
