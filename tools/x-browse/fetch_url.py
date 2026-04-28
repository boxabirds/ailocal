#!/usr/bin/env python3
"""Fetch an X.com URL with the user's auth cookies and dump the rendered tweets.

Use cases:
    - Browse a bookmark folder: https://x.com/i/bookmarks/<folder_id>
    - Read a thread:            https://x.com/<user>/status/<id>
    - Read a profile timeline:  https://x.com/<user>

Pattern follows ~/expts/x-bookmark-to-substack/src/bookmarks.py: persistent
Chrome context (channel="chrome") with cookies loaded from x_credentials.json,
which is shared with the bookmark-to-substack project (symlink in data/).

Usage:
    .venv/bin/python fetch_url.py <URL> [--max-scrolls N] [--output FILE]
                                       [--headless] [--format json|text]

Default is headed Chrome (max stealth, also lets you eyeball it).
"""

import argparse
import json
import logging
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
CREDS_FILE = REPO_ROOT / "data" / "x_credentials.json"
USER_DATA_DIR = REPO_ROOT / ".chrome-profile"

DEFAULT_MAX_SCROLLS = 20
SCROLL_PAUSE_S = 1.5
NETWORK_IDLE_TIMEOUT_MS = 15_000


def load_cookies():
    if not CREDS_FILE.exists():
        sys.exit(f"missing {CREDS_FILE} — symlink from reference repo or run refresh-x-auth")
    with open(CREDS_FILE) as f:
        creds = json.load(f)
    cookies = creds.get("all_cookies") or []
    if not cookies:
        sys.exit("x_credentials.json has no all_cookies — re-run refresh-x-auth")
    return cookies


def extract_tweets(page):
    """Return list of {author, handle, time, text, url} dicts from rendered DOM."""
    return page.evaluate(
        """() => {
        const out = [];
        for (const a of document.querySelectorAll('article[data-testid="tweet"]')) {
            const userEl = a.querySelector('[data-testid="User-Name"]');
            let author = '', handle = '';
            if (userEl) {
                const spans = userEl.querySelectorAll('span');
                for (const s of spans) {
                    const t = s.innerText.trim();
                    if (!t) continue;
                    if (t.startsWith('@') && !handle) handle = t;
                    else if (!author && !t.startsWith('@')) author = t;
                }
            }
            const tEl = a.querySelector('time');
            const time_iso = tEl ? tEl.getAttribute('datetime') : null;
            const linkEl = tEl ? tEl.closest('a') : null;
            const url = linkEl ? new URL(linkEl.href, location.origin).toString() : null;
            const textEl = a.querySelector('[data-testid="tweetText"]');
            const text = textEl ? textEl.innerText : '';
            out.push({ author, handle, time: time_iso, url, text });
        }
        return out;
    }"""
    )


def fetch(url: str, max_scrolls: int, headless: bool):
    from patchright.sync_api import sync_playwright

    cookies = load_cookies()
    USER_DATA_DIR.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            user_data_dir=str(USER_DATA_DIR),
            channel="chrome",
            headless=headless,
            no_viewport=True,
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        ctx.add_cookies(cookies)

        logging.info(f"navigating to {url}")
        page.goto(url, wait_until="domcontentloaded")
        try:
            page.wait_for_load_state("networkidle", timeout=NETWORK_IDLE_TIMEOUT_MS)
        except Exception:
            pass  # X.com keeps long polling; continue anyway

        # Auth check — bookmark URLs redirect to /i/flow/login if cookies are stale
        cur = page.url
        if "/login" in cur or "/i/flow/login" in cur:
            ctx.close()
            sys.exit(
                f"redirected to login ({cur}) — cookies stale; refresh from the "
                "x-bookmark-to-substack project or re-run refresh-x-auth"
            )

        seen_ids = set()
        all_tweets = []
        for i in range(max_scrolls):
            batch = extract_tweets(page)
            new_count = 0
            for t in batch:
                key = t.get("url") or (t.get("handle"), t.get("time"), t.get("text", "")[:80])
                if key in seen_ids:
                    continue
                seen_ids.add(key)
                all_tweets.append(t)
                new_count += 1
            logging.info(f"scroll {i+1}/{max_scrolls}: +{new_count} new (total {len(all_tweets)})")
            if i + 1 < max_scrolls:
                page.evaluate("window.scrollBy(0, window.innerHeight * 1.5)")
                time.sleep(SCROLL_PAUSE_S)

        ctx.close()
    return all_tweets


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("url")
    ap.add_argument("--max-scrolls", type=int, default=DEFAULT_MAX_SCROLLS)
    ap.add_argument("--output", help="write JSON/text to this path (default stdout)")
    ap.add_argument("--headless", action="store_true",
                    help="run Chrome headless (default: headed for stealth)")
    ap.add_argument("--format", choices=["json", "text"], default="json")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.INFO if args.verbose else logging.WARNING,
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stderr,
    )

    tweets = fetch(args.url, args.max_scrolls, args.headless)

    if args.format == "json":
        out = json.dumps(tweets, indent=2, ensure_ascii=False)
    else:
        lines = []
        for t in tweets:
            who = f"{t.get('author') or '?'} ({t.get('handle') or '?'})"
            when = t.get("time") or "?"
            lines.append(f"--- {who} · {when} ---")
            lines.append(t.get("text", ""))
            if t.get("url"):
                lines.append(t["url"])
            lines.append("")
        out = "\n".join(lines)

    if args.output:
        Path(args.output).write_text(out)
        print(f"wrote {len(tweets)} tweets to {args.output}", file=sys.stderr)
    else:
        print(out)


if __name__ == "__main__":
    main()
