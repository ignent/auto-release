#!/usr/bin/env python3
import argparse
from html.parser import HTMLParser
import json
import re
import sys
from urllib.parse import urlparse


BUTTON_ID = "onlyoffice_documents_for_android_arm"
OFFICIAL_HOST = "download.onlyoffice.com"


class NextDataParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_next_data = False
        self.parts = []

    def handle_starttag(self, tag, attrs):
        if tag == "script" and dict(attrs).get("id") == "__NEXT_DATA__":
            self.in_next_data = True

    def handle_data(self, data):
        if self.in_next_data:
            self.parts.append(data)

    def handle_endtag(self, tag):
        if tag == "script":
            self.in_next_data = False


def iter_dicts(value):
    if isinstance(value, dict):
        yield value
        for nested in value.values():
            yield from iter_dicts(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from iter_dicts(nested)


def validate_apk_url(url):
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != OFFICIAL_HOST or not parsed.path.lower().endswith(".apk"):
        raise ValueError("expected official HTTPS APK URL")
    return url


def extract_apk_url(html):
    parser = NextDataParser()
    parser.feed(html)
    if not parser.parts:
        raise ValueError("ONLYOFFICE page has no __NEXT_DATA__ payload")

    for value in iter_dicts(json.loads("".join(parser.parts))):
        if value.get("id") == BUTTON_ID:
            href = ((value.get("link") or {}).get("href") or "").strip()
            return validate_apk_url(href)

    raise ValueError("ONLYOFFICE Android APK button not found")


def extract_google_play_version(html):
    match = re.search(r'\[\[\["([0-9]+(?:\.[0-9]+)+(?:[-+._A-Za-z0-9]*)?)"\]\]', html)
    return match.group(1) if match else ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("apk-url", "google-play-version", "validate-url"))
    args = parser.parse_args()
    value = sys.stdin.read()

    if args.mode == "apk-url":
        print(extract_apk_url(value))
    elif args.mode == "google-play-version":
        print(extract_google_play_version(value))
    else:
        print(validate_apk_url(value.strip()))


if __name__ == "__main__":
    main()
