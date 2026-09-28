# Configurable Reddit scraper

This package polls configured subreddits through Reddit's official OAuth API and
upserts submission records into PostgreSQL. It is IPv4-only because IPv6
connections are blackholed on the target ISP. It uses no proxy rotation,
multiple accounts, CAPTCHA bypass, or other rate-limit evasion: it identifies
itself with a configurable User-Agent, honors Reddit's rate-limit headers and
`Retry-After`, uses exponential backoff for 429/5xx/network errors, and waits
between pages. Keep polling intervals conservative and comply with Reddit's
current API terms and access requirements.

## Configuration

Copy `config.example.toml` to `config.toml` and choose subreddits:

```toml
subreddits = ["NixOS", "AskReddit"]

[scraper]
limit_per_subreddit = 100 # 1–1000 recent posts per cycle
poll_interval_seconds = 900 # minimum 60; 15 minutes by default
```

The scraper requests `/r/{subreddit}/new`, paging in batches of at most 100 (up to the API's 1000-item listing window) if the limit exceeds one page.
Rows are keyed by Reddit's post ID. Repeated observations update mutable counts
and retain the original identity; all returned fields are also preserved in a
`JSONB` `raw` column. The table is created on first run. This gathers only
submissions and does not fetch comments.

## Run with Docker Compose (PostgreSQL + scraper)

The compose stack builds the scraper container and runs it alongside a
persistent PostgreSQL 16 container. Make a Reddit application with type
`script` at <https://www.reddit.com/prefs/apps>, then prepare local files:

```sh
cp .env.example .env
cp config.example.toml config.toml
# Edit .env: set credentials, a real descriptive User-Agent, and a strong DB password.
# Edit config.toml to list the desired subreddits.
docker compose -f compose.yaml up -d --build
docker compose -f compose.yaml logs -f scraper
```

Secrets are supplied through `.env` and are not baked into the image. PostgreSQL
is only exposed on the compose network; data survives restarts in the named
`reddit-postgres` volume. To stop the stack while retaining data, use
`docker compose -f compose.yaml down` (do not add `-v` unless you intend to
delete the database volume).

## Requirements for a live scrape

A successful live scrape requires all of the following:

1. **Reddit OAuth credentials:** create an application of type `script` at
   <https://www.reddit.com/prefs/apps> and provide its client ID and secret as
   `REDDIT_CLIENT_ID` and `REDDIT_CLIENT_SECRET`. Set `REDDIT_USER_AGENT` to a
   descriptive value identifying the application and account. Without these,
   the scraper cannot obtain an OAuth token or call Reddit's API.
2. **A configured subreddit list:** create `config.toml` from
   `config.example.toml` and list the subreddits to collect.
3. **A reachable PostgreSQL database:** set `DATABASE_URL`, or set
   `PGHOST`, `PGDATABASE`, `PGUSER`, and `PGPASSWORD` (and optionally
   `PGPORT`). The scraper creates its table on first run. For Compose, set
   `POSTGRES_PASSWORD` in `.env`; the included stack starts PostgreSQL and
   configures the scraper to connect to it.
4. **A running deployment and network access:** start the Compose stack with
   `docker compose -f compose.yaml up -d --build`, or run the Nix CLI where it
   can reach the configured database. The host must be able to reach Reddit's
   OAuth/API endpoints over IPv4.

The package and CLI were built and checked, but a live scrape was not run in
this environment: no Reddit credentials or configured/running PostgreSQL
instance were available, and the Docker Compose plugin was not installed to
start the bundled stack. These are deployment prerequisites, not additional
scraper configuration hidden in the package.

## Run as a Nix package

The repository exports `reddit-scraper` as
`packages.x86_64-linux.scrapers.reddit`. The package includes the Python CLI,
PostgreSQL driver, sample configuration, Dockerfile, and compose file. Supply
`DATABASE_URL` (or `PGHOST`, `PGDATABASE`, `PGUSER`, and `PGPASSWORD`) plus
`REDDIT_CLIENT_ID` and `REDDIT_CLIENT_SECRET`:

```sh
reddit-scraper --config ./config.toml --once
reddit-scraper --config ./config.toml # poll indefinitely
```

`REDDIT_USER_AGENT` should identify your application and Reddit account. The
OAuth credentials are sent only to Reddit's token endpoint and are not logged.
The network transport explicitly opens AF_INET sockets so DNS-provided IPv6
addresses cannot cause the ISP's IPv6 blackhole to stall requests.
