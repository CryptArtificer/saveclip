import Foundation

enum SensitiveDetector {
    // Compiled regexes, built once
    private static let matchers: [(label: String, regex: NSRegularExpression)] = {
        patterns.compactMap { p in
            guard let re = try? NSRegularExpression(pattern: p.pattern, options: []) else { return nil }
            return (label: p.label, regex: re)
        }
    }()

    private static var userMatchers: [(label: String, regex: NSRegularExpression)] = []

    static func setUserPatterns(_ patterns: [String]) {
        userMatchers = patterns.compactMap { p in
            guard let re = try? NSRegularExpression(pattern: p, options: []) else { return nil }
            return (label: "user pattern", regex: re)
        }
    }

    struct Match {
        let label: String
    }

    static func check(_ text: String) -> Match? {
        let range = NSRange(text.startIndex..., in: text)
        for m in matchers {
            if m.regex.firstMatch(in: text, range: range) != nil {
                return Match(label: m.label)
            }
        }
        for m in userMatchers {
            if m.regex.firstMatch(in: text, range: range) != nil {
                return Match(label: m.label)
            }
        }
        return nil
    }

    static func isSensitive(_ text: String) -> Bool {
        return check(text) != nil
    }

    // ── Pattern definitions ──────────────────────────────────────────

    private struct Pattern {
        let label: String
        let pattern: String
    }

    private static let patterns: [Pattern] = [
        // ── Private keys ──
        Pattern(label: "private key", pattern: "-----BEGIN [A-Z ]*PRIVATE KEY-----"),
        Pattern(label: "SSH key", pattern: "ssh-(rsa|ed25519|dss|ecdsa) AAAA"),
        Pattern(label: "PGP private", pattern: "-----BEGIN PGP PRIVATE KEY BLOCK-----"),

        // ── AWS ──
        Pattern(label: "AWS access key", pattern: "AKIA[0-9A-Z]{16}"),
        Pattern(label: "AWS secret key", pattern: "(?i)(aws_secret_access_key|aws_secret)\\s*[=:]\\s*[A-Za-z0-9/+=]{40}"),
        Pattern(label: "AWS session token", pattern: "(?i)aws_session_token\\s*[=:]\\s*[A-Za-z0-9/+=]{100,}"),

        // ── GitHub ──
        Pattern(label: "GitHub PAT", pattern: "ghp_[0-9a-zA-Z]{36}"),
        Pattern(label: "GitHub fine-grained PAT", pattern: "github_pat_[0-9a-zA-Z_]{22,}"),
        Pattern(label: "GitHub OAuth", pattern: "gho_[0-9a-zA-Z]{36}"),
        Pattern(label: "GitHub user token", pattern: "ghu_[0-9a-zA-Z]{36}"),
        Pattern(label: "GitHub server token", pattern: "ghs_[0-9a-zA-Z]{36}"),
        Pattern(label: "GitHub refresh token", pattern: "ghr_[0-9a-zA-Z]{36}"),

        // ── GitLab ──
        Pattern(label: "GitLab PAT", pattern: "glpat-[0-9a-zA-Z_-]{20,}"),
        Pattern(label: "GitLab runner token", pattern: "GR1348941[0-9a-zA-Z_-]{20,}"),

        // ── AI / LLM ──
        Pattern(label: "OpenAI key", pattern: "sk-[0-9a-zA-Z]{20,}T3BlbkFJ[0-9a-zA-Z]{20,}"),
        Pattern(label: "OpenAI project key", pattern: "sk-proj-[0-9a-zA-Z_-]{20,}"),
        Pattern(label: "Anthropic key", pattern: "sk-ant-[0-9a-zA-Z_-]{20,}"),

        // ── Cloud providers ──
        Pattern(label: "Google API key", pattern: "AIza[0-9A-Za-z_-]{35}"),
        Pattern(label: "Google OAuth", pattern: "[0-9]+-[0-9A-Za-z_]{32}\\.apps\\.googleusercontent\\.com"),
        Pattern(label: "Azure secret", pattern: "(?i)(azure|az)[_-]?(client|tenant)?[_-]?secret\\s*[=:]\\s*[A-Za-z0-9_-]{30,}"),
        Pattern(label: "DigitalOcean token", pattern: "dop_v1_[0-9a-f]{64}"),
        Pattern(label: "DigitalOcean OAuth", pattern: "doo_v1_[0-9a-f]{64}"),

        // ── Payment ──
        Pattern(label: "Stripe secret key", pattern: "sk_live_[0-9a-zA-Z]{24,}"),
        Pattern(label: "Stripe restricted key", pattern: "rk_live_[0-9a-zA-Z]{24,}"),
        Pattern(label: "Stripe webhook secret", pattern: "whsec_[0-9a-zA-Z]{32,}"),

        // ── Communication ──
        Pattern(label: "Slack token", pattern: "xox[bpars]-[0-9a-zA-Z-]{10,}"),
        Pattern(label: "Slack webhook", pattern: "https://hooks\\.slack\\.com/services/T[0-9A-Z]{8,}/B[0-9A-Z]{8,}/[0-9a-zA-Z]{24}"),
        Pattern(label: "Discord bot token", pattern: "[MN][A-Za-z0-9]{23,}\\.[A-Za-z0-9_-]{6}\\.[A-Za-z0-9_-]{27,}"),
        Pattern(label: "Twilio key", pattern: "SK[0-9a-fA-F]{32}"),
        Pattern(label: "SendGrid key", pattern: "SG\\.[a-zA-Z0-9_-]{22}\\.[a-zA-Z0-9_-]{43}"),

        // ── Package registries ──
        Pattern(label: "npm token", pattern: "npm_[0-9a-zA-Z]{36}"),
        Pattern(label: "PyPI token", pattern: "pypi-[0-9a-zA-Z_-]{50,}"),
        Pattern(label: "NuGet API key", pattern: "oy2[0-9a-z]{43}"),
        Pattern(label: "RubyGems key", pattern: "rubygems_[0-9a-f]{48}"),

        // ── Infrastructure ──
        Pattern(label: "Vault token", pattern: "hvs\\.[0-9a-zA-Z]{24,}"),
        Pattern(label: "Terraform token", pattern: "(?i)terraform[_-]?token\\s*[=:]\\s*[0-9a-zA-Z.]{14,}"),
        Pattern(label: "Heroku API key", pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"),
        Pattern(label: "Datadog API key", pattern: "(?i)(dd|datadog)[_-]?(api|app)?[_-]?key\\s*[=:]\\s*[0-9a-f]{32,}"),

        // ── JWT ──
        Pattern(label: "JWT", pattern: "eyJ[0-9a-zA-Z_-]{20,}\\.eyJ[0-9a-zA-Z_-]{20,}\\.[0-9a-zA-Z_-]{20,}"),

        // ── Database connection strings ──
        Pattern(label: "DB connection string", pattern: "(?i)(mysql|postgres|postgresql|mongodb|redis|amqp)://[^\\s:]+:[^\\s@]+@"),

        // ── Generic secret assignment ──
        Pattern(label: "secret assignment", pattern: "(?i)(password|passwd|secret|token|api_key|apikey|api-key|auth_token|access_token|private_key)\\s*[=:]\\s*[\"']?[A-Za-z0-9/+=_-]{16,}"),
        Pattern(label: "Bearer token", pattern: "(?i)bearer\\s+[A-Za-z0-9_-]{20,}"),
        Pattern(label: "Basic auth", pattern: "(?i)basic\\s+[A-Za-z0-9+/=]{20,}"),

        // ── .env style ──
        Pattern(label: "env secret", pattern: "(?i)^\\s*(SECRET|TOKEN|KEY|PASSWORD|PASSWD|API_KEY|PRIVATE_KEY|ACCESS_KEY)\\s*=\\s*\\S{8,}"),
    ]
}
