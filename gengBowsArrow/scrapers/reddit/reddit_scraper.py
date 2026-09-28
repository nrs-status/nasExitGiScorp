#!/usr/bin/env python3
"""Collect Reddit submissions using Reddit's OAuth API and store them in PostgreSQL."""

import argparse
import http.client
import json
import logging
import os
import random
import socket
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request

import psycopg2
from psycopg2.extras import Json

API = "https://oauth.reddit.com"
TOKEN_URL = "https://www.reddit.com/api/v1/access_token"
USER_AGENT = os.environ.get("REDDIT_USER_AGENT", "linux:configurable-subreddit-archiver:1.0 (by /u/configurable-scraper)")


class IPv4HTTPSConnection(http.client.HTTPSConnection):
    """Use IPv4 only: some networks silently blackhole IPv6 connections."""

    def connect(self):
        # socket.create_connection() may select AF_INET6 from DNS results. Resolve
        # with AF_INET explicitly, then connect to one of those IPv4 addresses.
        last_error = None
        for family, socktype, proto, _, address in socket.getaddrinfo(
            self.host, self.port, socket.AF_INET, socket.SOCK_STREAM
        ):
            sock = socket.socket(family, socktype, proto)
            try:
                sock.settimeout(self.timeout)
                if self.source_address:
                    sock.bind(self.source_address)
                sock.connect(address)
                break
            except OSError as exc:
                last_error = exc
                sock.close()
        else:
            if last_error:
                raise last_error
            raise OSError(f"no IPv4 address found for {self.host}")
        if self._tunnel_host:
            self.sock = sock
            self._tunnel()
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


class IPv4HTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(IPv4HTTPSConnection, req, context=self._context, check_hostname=self._check_hostname)


OPENER = urllib.request.build_opener(IPv4HTTPSHandler())


def http_json(url, *, headers=None, data=None, timeout=30):
    request = urllib.request.Request(url, data=data, headers=headers or {})
    with OPENER.open(request, timeout=timeout) as response:
        return json.loads(response.read()), response.headers


def load_config(path):
    with open(path, "rb") as config_file:
        config = tomllib.load(config_file)
    subs = config.get("subreddits")
    if not isinstance(subs, list) or not subs or any(not isinstance(s, str) or not s.strip() for s in subs):
        raise ValueError("config must contain a non-empty subreddits = [\"name\", ...] list")
    normalized = [s.strip().removeprefix("r/") for s in subs]
    if any(not s.isalnum() and "_" not in s for s in normalized):
        raise ValueError("subreddit names may contain only letters, digits, and underscores")
    settings = config.get("scraper", {})
    limit = int(settings.get("limit_per_subreddit", 100))
    if not 1 <= limit <= 1000:
        raise ValueError("limit_per_subreddit must be between 1 and 1000")
    interval = float(settings.get("poll_interval_seconds", 900))
    if interval < 60:
        raise ValueError("poll_interval_seconds must be at least 60 to avoid excessive API traffic")
    return normalized, limit, interval


def oauth_token():
    client_id = os.environ.get("REDDIT_CLIENT_ID")
    client_secret = os.environ.get("REDDIT_CLIENT_SECRET")
    if not client_id or not client_secret:
        raise ValueError("set REDDIT_CLIENT_ID and REDDIT_CLIENT_SECRET (create a Reddit script application)")
    basic = (client_id + ":" + client_secret).encode()
    import base64
    headers = {
        "Authorization": "Basic " + base64.b64encode(basic).decode(),
        "User-Agent": USER_AGENT,
        "Content-Type": "application/x-www-form-urlencoded",
    }
    body = urllib.parse.urlencode({"grant_type": "client_credentials"}).encode()
    token, _ = http_json(TOKEN_URL, headers=headers, data=body)
    return token["access_token"], time.monotonic() + int(token.get("expires_in", 3600)) - 60


def connect_database():
    dsn = os.environ.get("DATABASE_URL")
    if dsn:
        return psycopg2.connect(dsn, connect_timeout=10)
    required = ("PGHOST", "PGDATABASE", "PGUSER", "PGPASSWORD")
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise ValueError("set DATABASE_URL or all of " + ", ".join(required))
    return psycopg2.connect(
        host=os.environ["PGHOST"], port=os.environ.get("PGPORT", "5432"),
        dbname=os.environ["PGDATABASE"], user=os.environ["PGUSER"],
        password=os.environ["PGPASSWORD"], connect_timeout=10,
    )


def initialize_database(conn):
    with conn, conn.cursor() as cursor:
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS reddit_posts (
                id TEXT PRIMARY KEY,
                subreddit TEXT NOT NULL,
                title TEXT NOT NULL,
                author TEXT,
                score INTEGER NOT NULL,
                created_utc DOUBLE PRECISION NOT NULL,
                permalink TEXT NOT NULL,
                selftext TEXT NOT NULL,
                url TEXT NOT NULL,
                num_comments INTEGER NOT NULL,
                upvote_ratio DOUBLE PRECISION,
                is_self BOOLEAN NOT NULL,
                fetched_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                raw JSONB NOT NULL
            )
        """)
        cursor.execute("CREATE INDEX IF NOT EXISTS reddit_posts_subreddit_created_idx ON reddit_posts (subreddit, created_utc DESC)")


def save_posts(conn, posts):
    if not posts:
        return
    rows = []
    for post in posts:
        rows.append((
            post["id"], post["subreddit"], post.get("title", ""), post.get("author"),
            post.get("score", 0), post.get("created_utc", 0), post.get("permalink", ""),
            post.get("selftext", ""), post.get("url", ""), post.get("num_comments", 0),
            post.get("upvote_ratio"), post.get("is_self", False), Json(post),
        ))
    with conn, conn.cursor() as cursor:
        cursor.executemany("""
            INSERT INTO reddit_posts (id, subreddit, title, author, score, created_utc,
                permalink, selftext, url, num_comments, upvote_ratio, is_self, raw)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (id) DO UPDATE SET
                score = EXCLUDED.score, num_comments = EXCLUDED.num_comments,
                upvote_ratio = EXCLUDED.upvote_ratio, fetched_at = NOW(), raw = EXCLUDED.raw
        """, rows)


def request_with_backoff(url, headers, token_state):
    delay = 5.0
    while True:
        if time.monotonic() >= token_state[1]:
            token_state[:] = oauth_token()
            headers["Authorization"] = "Bearer " + token_state[0]
        try:
            result, response_headers = http_json(url, headers=headers)
            remaining = response_headers.get("X-Ratelimit-Remaining")
            reset = response_headers.get("X-Ratelimit-Reset")
            if remaining is not None and reset is not None and float(remaining) < 2:
                wait = max(1, float(reset)) + random.random()
                logging.info("API budget nearly exhausted; waiting %.1fs", wait)
                time.sleep(wait)
            return result
        except urllib.error.HTTPError as exc:
            if exc.code not in (429, 500, 502, 503, 504):
                raise
            retry_after = exc.headers.get("Retry-After")
            wait = min(3600, max(float(retry_after or 0), delay) + random.random())
            logging.warning("Reddit returned HTTP %s; backing off for %.1fs", exc.code, wait)
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            wait = min(3600, delay + random.random())
            logging.warning("Reddit request failed (%s); retrying in %.1fs", exc, wait)
        time.sleep(wait)
        delay = min(300, delay * 2)


def scrape_subreddit(conn, subreddit, limit, token_state):
    headers = {"Authorization": "Bearer " + token_state[0], "User-Agent": USER_AGENT}
    after = None
    fetched = 0
    while fetched < limit:
        page_size = min(100, limit - fetched)
        query = {"limit": page_size, "raw_json": 1}
        if after:
            query["after"] = after
        url = f"{API}/r/{urllib.parse.quote(subreddit, safe='')}/new?{urllib.parse.urlencode(query)}"
        listing = request_with_backoff(url, headers, token_state)
        children = listing.get("data", {}).get("children", [])
        posts = [child["data"] for child in children if child.get("kind") == "t3"]
        save_posts(conn, posts)
        fetched += len(posts)
        after = listing.get("data", {}).get("after")
        logging.info("r/%s: stored %d posts (total this pass %d)", subreddit, len(posts), fetched)
        if not after or not posts:
            break
        time.sleep(2)
    return fetched


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-c", "--config", default=os.environ.get("REDDIT_CONFIG", "config.toml"))
    parser.add_argument("--once", action="store_true", help="scrape each configured subreddit once and exit")
    args = parser.parse_args()
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
    subreddits, limit, interval = load_config(args.config)
    token_state = [*oauth_token()]
    while True:
        conn = connect_database()
        try:
            initialize_database(conn)
            for subreddit in subreddits:
                try:
                    scrape_subreddit(conn, subreddit, limit, token_state)
                except urllib.error.HTTPError as exc:
                    logging.error("r/%s failed with HTTP %s: %s", subreddit, exc.code, exc.read().decode(errors="replace")[:500])
        finally:
            conn.close()
        if args.once:
            return
        logging.info("Scrape cycle complete; sleeping %.0f seconds", interval)
        time.sleep(interval)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as exc:
        logging.error("scraper stopped: %s", exc)
        sys.exit(1)
