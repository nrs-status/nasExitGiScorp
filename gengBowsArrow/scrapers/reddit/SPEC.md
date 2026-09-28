# Reddit scraper implementation notes

- Use Reddit's authenticated OAuth API, not unauthenticated HTML/JSON scraping.
- Restrict HTTPS connections to IPv4 due to the ISP's broken IPv6 path.
- Honor API request budgets, `Retry-After`, back off on transient failures, and
  use a conservative configurable polling interval. Do not rotate identities
  or proxies to evade API limits.
- Persist subreddit submissions in PostgreSQL with idempotent upserts and raw
  JSONB retention.
- Package the standalone CLI using this repository's Nix package convention;
  provide a Compose deployment containing the scraper and PostgreSQL services.
- Keep Reddit/DB secrets environment-injected and never commit user credentials.
