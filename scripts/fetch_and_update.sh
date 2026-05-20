#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
README_FILE="${ROOT_DIR}/README.md"
CONFIG_FILE="${ROOT_DIR}/sources.json"
DOWNLOAD_ROOT="${ROOT_DIR}/releases"
TMP_DIR="$(mktemp -d)"
SKIP_DOWNLOADS="${SKIP_DOWNLOADS:-0}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

log() {
  printf '[fetch] %s\n' "$*"
}

resolve_python_bin() {
  local candidate=""
  if command -v python3 >/dev/null 2>&1; then
    candidate="$(command -v python3)"
    if [[ "${candidate}" != *"/WindowsApps/python3" && "${candidate}" != *"\\WindowsApps\\python3.exe" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi
  if command -v python >/dev/null 2>&1; then
    command -v python
    return 0
  fi
  return 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

require_command curl
require_command jq
PYTHON_BIN="$(resolve_python_bin)" || {
  printf 'Missing required command: python3 or python\n' >&2
  exit 1
}
export PYTHONIOENCODING="UTF-8"
export PYTHONUTF8="1"

mkdir -p "${DOWNLOAD_ROOT}"

score_apk_name() {
  local lowered="${1,,}"
  local score=0

  [[ "${lowered}" != *.apk ]] && {
    echo -9999
    return
  }

  [[ "${lowered}" == *"arm64-v8a"* ]] && score=$((score + 100))
  [[ "${lowered}" == *"arm64v8"* ]] && score=$((score + 95))
  [[ "${lowered}" == *"arm64"* ]] && score=$((score + 90))
  [[ "${lowered}" == *"aarch64"* ]] && score=$((score + 85))
  [[ "${lowered}" == *"universal"* ]] && score=$((score + 70))
  [[ "${lowered}" == *"android"* ]] && score=$((score + 10))
  [[ "${lowered}" == *"release"* ]] && score=$((score + 3))

  local keyword
  for keyword in "armeabi-v7a" "armeabi" "x86_64" "x64" "x86" "windows" "linux" "macos" ".exe" ".dmg" ".deb" ".rpm" ".appimage"; do
    [[ "${lowered}" == *"${keyword}"* ]] && score=$((score - 80))
  done

  echo "${score}"
}

score_asset_name() {
  local name="$1"
  local extensions_json="$2"
  local preferred_json="$3"
  local avoid_json="$4"
  local lowered="${name,,}"
  local score=0
  local has_extension="false"

  while IFS= read -r extension; do
    [[ -z "${extension}" ]] && continue
    if [[ "${lowered}" == *"${extension,,}" ]]; then
      has_extension="true"
      break
    fi
  done < <(jq -r '.[]?' <<<"${extensions_json}")

  [[ "${has_extension}" != "true" ]] && {
    echo -9999
    return
  }

  if jq -e '.[]? | select(. == ".apk")' >/dev/null 2>&1 <<<"${extensions_json}"; then
    score="$(score_apk_name "${name}")"
  fi

  [[ "${lowered}" == *"release"* ]] && score=$((score + 20))
  [[ "${lowered}" == *"stable"* ]] && score=$((score + 10))
  [[ "${lowered}" == *"debug"* ]] && score=$((score - 80))

  local keyword
  while IFS= read -r keyword; do
    [[ -n "${keyword}" && "${lowered}" == *"${keyword,,}"* ]] && score=$((score + 35))
  done < <(jq -r '.[]?' <<<"${preferred_json}")

  while IFS= read -r keyword; do
    [[ -n "${keyword}" && "${lowered}" == *"${keyword,,}"* ]] && score=$((score - 80))
  done < <(jq -r '.[]?' <<<"${avoid_json}")

  echo "${score}"
}

download_file() {
  local url="$1"
  local output="$2"
  curl --fail --location --silent --show-error --retry 3 --output "${output}" "${url}"
}

json_escape() {
  "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

fetch_text() {
  curl --fail --location --silent --show-error --retry 3 "$1"
}

sanitize_filename() {
  "${PYTHON_BIN}" - "$1" <<'PY'
import re
import sys
print(re.sub(r'[\\/:*?"<>|]+', "_", sys.argv[1]))
PY
}

extract_filename_from_url() {
  "${PYTHON_BIN}" - "$1" <<'PY'
from urllib.parse import urlparse, unquote
import os
import sys
path = urlparse(sys.argv[1]).path
name = os.path.basename(path.rstrip("/"))
print(unquote(name))
PY
}

parse_last_modified_to_iso() {
  "${PYTHON_BIN}" - "$1" <<'PY'
from email.utils import parsedate_to_datetime
import sys
value = sys.argv[1].strip()
if not value:
    print("")
else:
    try:
        print(parsedate_to_datetime(value).isoformat())
    except Exception:
        print(value)
PY
}

fetch_antennapod_fallback() {
  local page_html page_html_file fdroid_url fdroid_html fdroid_html_file
  page_html="$(fetch_text "https://antennapod.org/download/")"
  page_html_file="$(mktemp "${TMP_DIR}/antennapod-page.XXXXXX.html")"
  printf '%s' "${page_html}" > "${page_html_file}"
  fdroid_url="$(
    PAGE_HTML_FILE="${page_html_file}" "${PYTHON_BIN}" <<'PY'
from html.parser import HTMLParser
from urllib.parse import urljoin
import os
import re

base_url = "https://antennapod.org/download/"
with open(os.environ["PAGE_HTML_FILE"], "r", encoding="utf-8") as fp:
    html = fp.read()

class Parser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.result = None

    def handle_starttag(self, tag, attrs):
        if tag != "a" or self.result is not None:
            return
        href = dict(attrs).get("href")
        if not href:
            return
        full = urljoin(base_url, href.strip())
        if "f-droid.org" in full and "/packages/de.danoeh.antennapod" in full:
            self.result = full

parser = Parser()
parser.feed(html)
if parser.result:
    print(parser.result)
else:
    match = re.search(r"https://f-droid\.org(?:/[a-z]{2})?/packages/de\.danoeh\.antennapod/?", html)
    print(match.group(0) if match else "https://f-droid.org/en/packages/de.danoeh.antennapod/")
PY
  )"
  [[ -z "${fdroid_url}" ]] && fdroid_url="https://f-droid.org/en/packages/de.danoeh.antennapod/"
  fdroid_html="$(fetch_text "${fdroid_url}")"
  fdroid_html_file="$(mktemp "${TMP_DIR}/antennapod-fdroid.XXXXXX.html")"
  printf '%s' "${fdroid_html}" > "${fdroid_html_file}"

  FDROID_HTML_FILE="${fdroid_html_file}" FDROID_URL="${fdroid_url}" "${PYTHON_BIN}" <<'PY'
from html.parser import HTMLParser
from urllib.parse import urljoin
from datetime import datetime
import json
import os
import re

with open(os.environ["FDROID_HTML_FILE"], "r", encoding="utf-8") as fp:
    html = fp.read()
page_url = os.environ["FDROID_URL"]

class Parser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.items = []
        self.capture_li = False
        self.li_depth = 0
        self.current_href = None
        self.current_text = []
        self.current_item = None
        self.in_header = False
        self.header_depth = 0

    def handle_starttag(self, tag, attrs):
        attrs_dict = dict(attrs)
        classes = attrs_dict.get("class", "")
        if tag == "li" and "package-version" in classes:
          self.capture_li = True
          self.li_depth = 1
          self.current_item = {"header": "", "links": []}
          return
        if not self.capture_li:
          return
        if tag == "li":
          self.li_depth += 1
        if tag == "div" and "package-version-header" in classes:
          self.in_header = True
          self.header_depth = 1
        elif self.in_header:
          self.header_depth += 1
        if tag == "a":
          self.current_href = attrs_dict.get("href")
          self.current_text = []

    def handle_data(self, data):
        if not self.capture_li:
          return
        text = data.strip()
        if not text:
          return
        if self.in_header:
          if self.current_item["header"]:
            self.current_item["header"] += " "
          self.current_item["header"] += text
        if self.current_href is not None:
          self.current_text.append(text)

    def handle_endtag(self, tag):
        if not self.capture_li:
          return
        if tag == "a" and self.current_href is not None:
          self.current_item["links"].append((" ".join(self.current_text).strip(), self.current_href))
          self.current_href = None
          self.current_text = []
        if self.in_header:
          self.header_depth -= 1
          if self.header_depth == 0:
            self.in_header = False
        if tag == "li":
          self.li_depth -= 1
          if self.li_depth == 0:
            self.items.append(self.current_item)
            self.current_item = None
            self.capture_li = False

parser = Parser()
parser.feed(html)
if not parser.items:
    raise SystemExit(json.dumps({"ok": False, "error": "F-Droid page has no package-version entries"}))

selected = None
for item in parser.items:
    if "suggested" in item["header"].lower():
        selected = item
        break
if selected is None:
    selected = parser.items[0]

version_match = re.search(r"Version\s+([^\s(]+)\s+\((\d+)\)", selected["header"])
version_name = version_match.group(1) if version_match else ""
date_match = re.search(r"Added on\s+([A-Za-z]{3,9}\s+\d{1,2},\s+\d{4})", selected["header"])
release_date = ""
if date_match:
    try:
        release_date = datetime.strptime(date_match.group(1), "%b %d, %Y").date().isoformat()
    except ValueError:
        try:
            release_date = datetime.strptime(date_match.group(1), "%B %d, %Y").date().isoformat()
        except ValueError:
            release_date = date_match.group(1)

apk_href = None
for text, href in selected["links"]:
    if text == "Download APK":
        apk_href = href
        break
if apk_href is None:
    raise SystemExit(json.dumps({"ok": False, "error": "F-Droid package entry has no Download APK link"}))

apk_url = urljoin(page_url, apk_href.strip())
apk_name = apk_url.rstrip("/").split("/")[-1] or "AntennaPod.apk"
print(json.dumps({
    "ok": True,
    "version": version_name,
    "updated_at": release_date,
    "download_url": apk_url,
    "asset_name": apk_name,
    "page_url": page_url
}, ensure_ascii=False))
PY
}

fetch_github_release_item() {
  local item_json="$1"
  local mode="$2"
  local name repo api_url releases_api_url response response_file response_status tag_name published_at html_url release_name extensions preferred avoid
  local -a github_headers=(
    -H 'Accept: application/vnd.github+json'
    -H 'User-Agent: auto-release-script'
    -H 'X-GitHub-Api-Version: 2022-11-28'
  )
  name="$(jq -r '.name' <<<"${item_json}")"
  repo="$(jq -r '.repo' <<<"${item_json}")"
  api_url="https://api.github.com/repos/${repo}/releases/latest"
  releases_api_url="https://api.github.com/repos/${repo}/releases?per_page=1"
  response_file="$(mktemp "${TMP_DIR}/github-release.XXXXXX.json")"
  if [[ -n "${GITHUB_TOKEN}" ]]; then
    github_headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  response_status="$(curl --location --silent --show-error --retry 3 \
    "${github_headers[@]}" \
    --output "${response_file}" \
    --write-out '%{http_code}' \
    "${api_url}")"

  if [[ "${response_status}" == "200" ]]; then
    response="$(cat "${response_file}")"
  else
    response_status="$(curl --location --silent --show-error --retry 3 \
      "${github_headers[@]}" \
      --output "${response_file}" \
      --write-out '%{http_code}' \
      "${releases_api_url}")"
    if [[ "${response_status}" == "200" && "$(jq -r 'if length > 0 then "true" else "false" end' "${response_file}")" == "true" ]]; then
      response="$(jq -c '.[0]' "${response_file}")"
    else
      response=""
    fi
  fi

  html_url="https://github.com/${repo}/releases"
  if [[ -n "${response}" ]]; then
    html_url="$(jq -r --arg repo "${repo}" '.html_url // ("https://github.com/" + $repo + "/releases/latest")' <<<"${response}")"
    tag_name="$(jq -r '.tag_name // .name // "N/A"' <<<"${response}")"
    published_at="$(jq -r '.published_at // ""' <<<"${response}")"
    release_name="$(jq -r '.name // ""' <<<"${response}")"
  else
    tag_name="N/A"
    published_at=""
    release_name=""
  fi
  extensions="$(jq -c '.extensions // []' <<<"${item_json}")"
  preferred="$(jq -c '.preferred_keywords // []' <<<"${item_json}")"
  avoid="$(jq -c '.avoid_keywords // []' <<<"${item_json}")"

  local best_name="" best_url="" best_score=-1000000 asset_name asset_url score

  while IFS= read -r asset; do
    [[ -z "${asset}" ]] && continue
    asset_name="$(jq -r '.name // ""' <<<"${asset}")"
    asset_url="$(jq -r '.browser_download_url // ""' <<<"${asset}")"
    [[ -z "${asset_name}" || -z "${asset_url}" ]] && continue

    if [[ "${mode}" == "github_apk" ]]; then
      score="$(score_apk_name "${asset_name}")"
    else
      score="$(score_asset_name "${asset_name}" "${extensions}" "${preferred}" "${avoid}")"
    fi

    if (( score > best_score )); then
      best_score="${score}"
      best_name="${asset_name}"
      best_url="${asset_url}"
    fi
  done < <(jq -c '.assets[]?' <<<"${response}")

  if [[ -z "${best_url}" && "${repo}" == "AntennaPod/AntennaPod" && "${mode}" == "github_apk" ]]; then
    local fallback_json
    fallback_json="$(fetch_antennapod_fallback)"
    if [[ "$(jq -r '.ok' <<<"${fallback_json}")" == "true" ]]; then
      jq -n \
        --arg name "${name}" \
        --arg repo "${repo}" \
        --arg version "$(jq -r '.version // "N/A"' <<<"${fallback_json}")" \
        --arg updated_at "$(jq -r '.updated_at // ""' <<<"${fallback_json}")" \
        --arg download_url "$(jq -r '.download_url' <<<"${fallback_json}")" \
        --arg asset_name "$(jq -r '.asset_name' <<<"${fallback_json}")" \
        --arg page_url "$(jq -r '.page_url' <<<"${fallback_json}")" \
        '{ok:true,name:$name,repo:$repo,version:$version,updated_at:$updated_at,download_url:$download_url,asset_name:$asset_name,source_url:$page_url}'
      return
    fi
  fi

  if [[ -z "${best_url}" ]]; then
    jq -n \
      --arg name "${name}" \
      --arg repo "${repo}" \
      --arg version "${tag_name}" \
      --arg updated_at "${published_at}" \
      --arg source_url "${html_url}" \
      '{ok:false,name:$name,repo:$repo,version:$version,updated_at:$updated_at,download_url:"",asset_name:"",source_url:$source_url,error:"No matching release asset found"}'
    return
  fi

  jq -n \
    --arg name "${name}" \
    --arg repo "${repo}" \
    --arg version "${tag_name}" \
    --arg updated_at "${published_at}" \
    --arg download_url "${best_url}" \
    --arg asset_name "${best_name}" \
    --arg source_url "${html_url}" \
    --arg release_name "${release_name}" \
    '{ok:true,name:$name,repo:$repo,version:$version,updated_at:$updated_at,download_url:$download_url,asset_name:$asset_name,source_url:$source_url,release_name:$release_name}'
}

fetch_direct_item() {
  local item_json="$1"
  local name url filename version_override
  name="$(jq -r '.name' <<<"${item_json}")"
  url="$(jq -r '.url' <<<"${item_json}")"
  filename="$(jq -r '.filename // ""' <<<"${item_json}")"
  version_override="$(jq -r '.version // ""' <<<"${item_json}")"

  local headers_file="${TMP_DIR}/headers.txt"
  local effective_url http_code
  http_code="$(curl --location --silent --show-error --retry 3 --dump-header "${headers_file}" --output /dev/null --write-out '%{http_code}' "${url}")"
  effective_url="$(curl --location --silent --show-error --retry 3 --output /dev/null --write-out '%{url_effective}' "${url}")"

  if [[ -z "${filename}" ]]; then
    filename="$(extract_filename_from_url "${effective_url}")"
  fi
  [[ -z "${filename}" ]] && filename="$(sanitize_filename "${name}").bin"

  local updated_at last_modified version
  last_modified="$(awk 'BEGIN{IGNORECASE=1} /^last-modified:/ {sub(/\r$/, "", $0); print substr($0, index($0,$2)); exit}' "${headers_file}")"
  updated_at="$(parse_last_modified_to_iso "${last_modified}")"
  version="${version_override}"
  [[ -z "${version}" ]] && version="${filename%.*}"
  [[ -z "${version}" ]] && version="N/A"

  jq -n \
    --arg ok "$([[ "${http_code}" =~ ^[23] ]] && echo true || echo false)" \
    --arg name "${name}" \
    --arg version "${version}" \
    --arg updated_at "${updated_at}" \
    --arg download_url "${url}" \
    --arg asset_name "${filename}" \
    --arg source_url "${url}" \
    '{ok:($ok == "true"),name:$name,version:$version,updated_at:$updated_at,download_url:$download_url,asset_name:$asset_name,source_url:$source_url}'
}

fetch_mt_item() {
  local item_json="$1"
  local name page_url html html_file
  name="$(jq -r '.name' <<<"${item_json}")"
  page_url="$(jq -r '.url' <<<"${item_json}")"
  html="$(fetch_text "${page_url}")"
  html_file="$(mktemp "${TMP_DIR}/mt-page.XXXXXX.html")"
  printf '%s' "${html}" > "${html_file}"

  PAGE_HTML_FILE="${html_file}" PAGE_URL="${page_url}" ITEM_NAME="${name}" "${PYTHON_BIN}" <<'PY'
from urllib.parse import urljoin
import json
import os
import re

page_url = os.environ["PAGE_URL"]
item_name = os.environ["ITEM_NAME"]

try:
    with open(os.environ["PAGE_HTML_FILE"], "r", encoding="utf-8") as fp:
        html = fp.read()

    text = re.sub(r"<[^>]+>", "\n", html)
    version_match = re.search(r"版本名[:：]\s*(v[^\s<]+)", text)
    date_match = re.search(r"发布时间[:：]\s*([0-9]{4}-[0-9]{2}-[0-9]{2})", text)
    version = version_match.group(1) if version_match else "N/A"
    updated_at = date_match.group(1) if date_match else ""

    candidates = []
    for href, label in re.findall(r'<a[^>]+href="([^"]+)"[^>]*>\s*<b>\s*&gt;&gt;\s*([^<]+)\s*</b>\s*</a>', html, re.S):
        if "TargetSdk28" not in label:
            continue
        score = 0
        if "正式版" in label:
            score += 50
        if "TargetSdk28" in label:
            score += 40
        if "本地下载" in label:
            score += 10
        if "共存" in label:
            score -= 100
        candidates.append((score, label.strip(), urljoin(page_url, href.strip())))

    if not candidates:
        print(json.dumps({
            "ok": False,
            "name": item_name,
            "version": version,
            "updated_at": updated_at,
            "download_url": "",
            "asset_name": "",
            "source_url": page_url,
            "error": "TargetSdk28 link not found"
        }, ensure_ascii=False))
    else:
        candidates.sort(key=lambda item: item[0], reverse=True)
        _, _, entry_url = candidates[0]
        version_suffix = version[1:] if version.startswith("v") else version
        asset_name = f"MT{version_suffix}-target28.apk" if version_suffix and version_suffix != "N/A" else "MT-target28.apk"
        print(json.dumps({
            "ok": True,
            "name": item_name,
            "version": version,
            "updated_at": updated_at,
            "download_url": entry_url,
            "asset_name": asset_name,
            "source_url": page_url
        }, ensure_ascii=False))
except Exception as exc:
    print(json.dumps({
        "ok": False,
        "name": item_name,
        "version": "N/A",
        "updated_at": "",
        "download_url": "",
        "asset_name": "",
        "source_url": page_url,
        "error": f"MT parser failed: {exc}"
    }, ensure_ascii=False))
PY
}

fetch_telegram_lsposed_item() {
  local item_json="$1"
  local name page_url html html_file
  name="$(jq -r '.name' <<<"${item_json}")"
  page_url="$(jq -r '.url' <<<"${item_json}")"
  html="$(fetch_text "${page_url}")"
  html_file="$(mktemp "${TMP_DIR}/lsposed-page.XXXXXX.html")"
  printf '%s' "${html}" > "${html_file}"

  PAGE_HTML_FILE="${html_file}" PAGE_URL="${page_url}" ITEM_NAME="${name}" "${PYTHON_BIN}" <<'PY'
import json
import os
import re

with open(os.environ["PAGE_HTML_FILE"], "r", encoding="utf-8") as fp:
    html = fp.read()
page_url = os.environ["PAGE_URL"]
item_name = os.environ["ITEM_NAME"]

matches = list(re.finditer(
    r'<a class="tgme_widget_message_document_wrap" href="([^"]+)">.*?<div class="tgme_widget_message_document_title[^>]*>(LSPosed-v[^<]+?\.zip)</div>.*?<time datetime="([^"]+)"',
    html,
    re.S,
))
if matches:
    latest = max(matches, key=lambda m: m.group(3))
    message_url = latest.group(1).strip()
    asset_name = latest.group(2).strip()
    updated_at = latest.group(3).strip()
    version_match = re.search(r'LSPosed-(v[^-]+(?:-[^-]+)*)-release\.zip', asset_name)
    version = version_match.group(1) if version_match else asset_name
    print(json.dumps({
        "ok": True,
        "name": item_name,
        "version": version,
        "updated_at": updated_at,
        "source_url": message_url,
        "metadata_only": True
    }, ensure_ascii=False))
else:
    print(json.dumps({
        "ok": False,
        "name": item_name,
        "version": "N/A",
        "updated_at": "",
        "source_url": page_url,
        "error": "Latest LSPosed Telegram post not found"
    }, ensure_ascii=False))
PY
}

iterate_group_items() {
  local group_json="$1"
  jq -c '.items[]?' <<<"${group_json}"
}

fetch_github_proxy_item() {
  local item_json="$1"
  ITEM_JSON="${item_json}" "${PYTHON_BIN}" <<'PY'
import json
import os
import urllib.error
import urllib.request

item = json.loads(os.environ["ITEM_JSON"])
name = item.get("name", "")
repo = item.get("repo", "").strip()
platforms = item.get("platforms", "")
source_url = item.get("source_url") or (f"https://github.com/{repo}" if repo else "")
github_token = os.environ.get("GITHUB_TOKEN", "").strip()


def emit(payload):
    print(json.dumps(payload, ensure_ascii=False))


def get_json(url):
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "auto-release-script",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if github_token:
        headers["Authorization"] = f"Bearer {github_token}"
    request = urllib.request.Request(
        url,
        headers=headers,
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        try:
            return exc.code, json.loads(body)
        except Exception:
            return exc.code, {}
    except Exception as exc:
        return 0, {"error": str(exc)}


def classify_platform(text):
    lowered = text.lower()
    has_android = "android" in lowered or "安卓" in text
    has_windows = "windows" in lowered or "win" in lowered
    has_linux = "linux" in lowered
    has_mac = "mac" in lowered
    count = sum((has_android, has_windows, has_linux, has_mac))
    if count != 1:
        return "multi"
    if has_android:
        return "android"
    if has_windows:
        return "windows"
    if has_linux:
        return "linux"
    return "mac"


RULES = {
    "android": {
        "exts": [".apk"],
        "prefer": ["arm64-v8a", "arm64", "universal", "android", "release"],
        "avoid": ["x86", "armeabi-v7a", "debug"],
    },
    "windows": {
        "exts": [".exe", ".msi", ".zip", ".7z"],
        "prefer": ["setup", "installer", "x64", "amd64", "win", "portable"],
        "avoid": ["debug", "symbols", "pdb", "arm64"],
    },
    "linux": {
        "exts": [".appimage", ".deb", ".rpm", ".tar.gz", ".tgz", ".tar.xz", ".zip"],
        "prefer": ["linux", "amd64", "x86_64"],
        "avoid": ["debug", "arm64", "aarch64"],
    },
    "mac": {
        "exts": [".dmg", ".pkg", ".zip"],
        "prefer": ["mac", "darwin", "universal", "apple"],
        "avoid": ["debug"],
    },
}


def score_asset(asset_name, platform_kind):
    lowered = asset_name.lower()
    if platform_kind == "multi":
        return -9999

    rule = RULES[platform_kind]
    base_score = None
    for index, extension in enumerate(rule["exts"]):
        if lowered.endswith(extension):
            base_score = 200 - (index * 20)
            break
    if base_score is None:
        return -9999

    score = base_score
    for keyword in rule["prefer"]:
        if keyword in lowered:
            score += 15
    for keyword in rule["avoid"]:
        if keyword in lowered:
            score -= 40
    if "release" in lowered:
        score += 10
    if "debug" in lowered:
        score -= 50
    return score


if not repo:
    emit({
        "ok": False,
        "name": name,
        "version": "N/A",
        "updated_at": "",
        "download_url": "",
        "asset_name": "",
        "source_url": source_url,
        "error": "GitHub repository could not be resolved",
    })
    raise SystemExit

release = None
status, payload = get_json(f"https://api.github.com/repos/{repo}/releases/latest")
if status == 200 and isinstance(payload, dict) and payload.get("id"):
    release = payload

if release is None:
    status, payload = get_json(f"https://api.github.com/repos/{repo}/releases?per_page=1")
    if status == 200 and isinstance(payload, list) and payload:
        release = payload[0]

if release is not None:
    release_url = release.get("html_url") or f"https://github.com/{repo}/releases"
    version = release.get("tag_name") or release.get("name") or "N/A"
    updated_at = release.get("published_at") or release.get("created_at") or ""
    assets = release.get("assets") or []
    platform_kind = classify_platform(platforms)

    chosen_asset = None
    if platform_kind == "multi":
        if len(assets) == 1:
            chosen_asset = assets[0]
    else:
        best_score = -9999
        for asset in assets:
            asset_name = asset.get("name") or ""
            asset_url = asset.get("browser_download_url") or ""
            if not asset_name or not asset_url:
                continue
            score = score_asset(asset_name, platform_kind)
            if score > best_score:
                best_score = score
                chosen_asset = asset

    if chosen_asset and chosen_asset.get("browser_download_url"):
        emit({
            "ok": True,
            "name": name,
            "version": version,
            "updated_at": updated_at,
            "download_url": chosen_asset.get("browser_download_url", ""),
            "asset_name": chosen_asset.get("name", ""),
            "source_url": release_url,
        })
    else:
        emit({
            "ok": True,
            "name": name,
            "version": version,
            "updated_at": updated_at,
            "download_url": "",
            "asset_name": "",
            "source_url": release_url,
            "metadata_only": True,
        })
    raise SystemExit

status, payload = get_json(f"https://api.github.com/repos/{repo}/tags?per_page=1")
if status == 200 and isinstance(payload, list) and payload:
    latest_tag = payload[0]
    version = latest_tag.get("name") or "N/A"
    updated_at = ""
    commit_sha = ((latest_tag.get("commit") or {}).get("sha") or "").strip()
    if commit_sha:
        commit_status, commit_payload = get_json(f"https://api.github.com/repos/{repo}/commits/{commit_sha}")
        if commit_status == 200 and isinstance(commit_payload, dict):
            updated_at = (((commit_payload.get("commit") or {}).get("committer") or {}).get("date") or "")
    emit({
        "ok": True,
        "name": name,
        "version": version,
        "updated_at": updated_at,
        "download_url": "",
        "asset_name": "",
        "source_url": f"https://github.com/{repo}/tags",
        "metadata_only": True,
    })
    raise SystemExit

status, payload = get_json(f"https://api.github.com/repos/{repo}/commits?per_page=1")
if status == 200 and isinstance(payload, list) and payload:
    latest_commit = payload[0]
    emit({
        "ok": True,
        "name": name,
        "version": ((latest_commit.get("sha") or "")[:7] or "N/A"),
        "updated_at": (((latest_commit.get("commit") or {}).get("committer") or {}).get("date") or ""),
        "download_url": "",
        "asset_name": "",
        "source_url": latest_commit.get("html_url") or source_url,
        "metadata_only": True,
    })
    raise SystemExit

emit({
    "ok": False,
    "name": name,
    "version": "N/A",
    "updated_at": "",
    "download_url": "",
    "asset_name": "",
    "source_url": source_url,
    "error": "GitHub metadata lookup failed",
})
PY
}

fetch_apple_app_store_item() {
  local item_json="$1"
  ITEM_JSON="${item_json}" "${PYTHON_BIN}" <<'PY'
import json
import os
import re
import urllib.error
import urllib.request

item = json.loads(os.environ["ITEM_JSON"])
name = item.get("name", "")
url = item.get("url", "")


def emit(payload):
    print(json.dumps(payload, ensure_ascii=False))


def get_json(request_url):
    request = urllib.request.Request(
        request_url,
        headers={"Accept": "application/json", "User-Agent": "auto-release-script"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        try:
            return exc.code, json.loads(body)
        except Exception:
            return exc.code, {}
    except Exception as exc:
        return 0, {"error": str(exc)}


match = re.search(r"/([a-z]{2})/app/.+/id(\d+)", url)
fallback_match = re.search(r"/id(\d+)", url)
country = match.group(1) if match else "us"
app_id = match.group(2) if match else (fallback_match.group(1) if fallback_match else "")

if not app_id:
    emit({
        "ok": False,
        "name": name,
        "version": "N/A",
        "updated_at": "",
        "download_url": "",
        "asset_name": "",
        "source_url": url,
        "error": "App Store app id not found",
    })
    raise SystemExit

lookup_urls = [
    f"https://itunes.apple.com/lookup?id={app_id}&country={country}",
    f"https://itunes.apple.com/lookup?id={app_id}",
]

result = None
for lookup_url in lookup_urls:
    status, payload = get_json(lookup_url)
    if status == 200 and isinstance(payload, dict) and payload.get("resultCount"):
        result = payload["results"][0]
        break

if result is None:
    emit({
        "ok": False,
        "name": name,
        "version": "N/A",
        "updated_at": "",
        "download_url": "",
        "asset_name": "",
        "source_url": url,
        "error": "App Store lookup failed",
    })
    raise SystemExit

emit({
    "ok": True,
    "name": name,
    "version": result.get("version") or "N/A",
    "updated_at": result.get("currentVersionReleaseDate") or result.get("releaseDate") or "",
    "download_url": "",
    "asset_name": "",
    "source_url": result.get("trackViewUrl") or url,
    "metadata_only": True,
})
PY
}

fetch_page_metadata_item() {
  local item_json="$1"
  ITEM_JSON="${item_json}" "${PYTHON_BIN}" <<'PY'
import html
import json
import os
import re
import urllib.error
import urllib.request
from email.utils import parsedate_to_datetime

item = json.loads(os.environ["ITEM_JSON"])
name = item.get("name", "")
url = item.get("url", "")
version_override = item.get("version", "")


def emit(payload):
    print(json.dumps(payload, ensure_ascii=False))


def normalize_last_modified(value):
    value = (value or "").strip()
    if not value:
        return ""
    try:
        return parsedate_to_datetime(value).isoformat()
    except Exception:
        return value


def extract_version(text):
    for pattern in (
        r"(?i)(?:version|版本|ver\.?)\s*[:：]?\s*(v?\d+(?:\.\d+){1,5}(?:[-._a-z0-9]+)?)",
        r"(?<!\w)(v\d+(?:\.\d+){1,5}(?:[-._a-z0-9]+)?)(?!\w)",
        r"(?<!\w)(\d+(?:\.\d+){2,5}(?:[-._a-z0-9]+)?)(?!\w)",
    ):
        match = re.search(pattern, text)
        if match:
            return match.group(1)
    return ""


request = urllib.request.Request(url, headers={"User-Agent": "auto-release-script"})
try:
    with urllib.request.urlopen(request, timeout=30) as response:
        status = response.status
        final_url = response.geturl()
        headers = response.headers
        body = response.read(250000).decode("utf-8", errors="ignore")
except urllib.error.HTTPError as exc:
    status = exc.code
    final_url = exc.geturl() or url
    headers = exc.headers
    body = exc.read(250000).decode("utf-8", errors="ignore")
except Exception as exc:
    emit({
        "ok": False,
        "name": name,
        "version": version_override or "N/A",
        "updated_at": "",
        "download_url": "",
        "asset_name": "",
        "source_url": url,
        "error": str(exc),
    })
    raise SystemExit

title_match = re.search(r"<title[^>]*>(.*?)</title>", body, re.I | re.S)
title_text = html.unescape(title_match.group(1)).strip() if title_match else ""
plain_text = re.sub(r"<[^>]+>", " ", body)
plain_text = html.unescape(re.sub(r"\s+", " ", plain_text)).strip()
version = version_override or extract_version(title_text) or extract_version(plain_text[:12000]) or "N/A"

emit({
    "ok": 200 <= status < 400,
    "name": name,
    "version": version,
    "updated_at": normalize_last_modified(headers.get("Last-Modified", "")),
    "download_url": "",
    "asset_name": "",
    "source_url": final_url or url,
    "metadata_only": True,
    "error": "" if 200 <= status < 400 else f"HTTP {status}",
})
PY
}

fetch_static_metadata_item() {
  local item_json="$1"
  jq -n \
    --arg name "$(jq -r '.name' <<<"${item_json}")" \
    '{ok:false,name:$name,version:"N/A",updated_at:"",download_url:"",asset_name:"",source_url:"",error:"No source URL available"}'
}

extract_existing_group_rows() {
  local group_json="$1"
  local output_file="$2"
  local start_marker end_marker
  start_marker="$(jq -r '.start_marker' <<<"${group_json}")"
  end_marker="$(jq -r '.end_marker' <<<"${group_json}")"

  "${PYTHON_BIN}" - "${README_FILE}" "${start_marker}" "${end_marker}" "${output_file}" <<'PY'
from pathlib import Path
import json
import re
import sys

readme_path = Path(sys.argv[1])
start_marker = sys.argv[2]
end_marker = sys.argv[3]
output_path = Path(sys.argv[4])

text = readme_path.read_text(encoding="utf-8")
start_index = text.find(start_marker)
end_index = text.find(end_marker)
rows = []

if start_index != -1 and end_index != -1 and end_index > start_index:
    section = text[start_index + len(start_marker):end_index]
    for line in section.splitlines():
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) != 5:
            continue
        if cells[0] == "序号" or cells[0].replace("-", "") == "":
            continue

        _, name, version, updated_at, link_cell = cells
        download_label = ""
        download_url = ""
        source_url = ""
        status = False

        match = re.fullmatch(r"\[(.*?)\]\((.*?)\)", link_cell)
        if match:
            label, url = match.groups()
            if label in {"查看来源", "前往下载", "最新版本页"}:
                source_url = url
            else:
                download_label = label
                download_url = url
                status = True
        rows.append({
            "name": name,
            "version": version,
            "updated_at": updated_at,
            "download_label": download_label,
            "download_url": download_url,
            "source_url": source_url,
            "status": status,
        })

with output_path.open("w", encoding="utf-8") as fp:
    for row in rows:
        fp.write(json.dumps(row, ensure_ascii=False) + "\n")
PY
}

format_markdown_link() {
  local label="$1"
  local url="$2"
  printf '[%s](%s)' "${label}" "${url}"
}

resolve_proxy_item_page_url() {
  local item_json="$1"
  local source_type source_url repo url
  source_type="$(jq -r '.type' <<<"${item_json}")"
  case "${source_type}" in
    github_proxy)
      source_url="$(jq -r '.source_url // ""' <<<"${item_json}")"
      if [[ -n "${source_url}" ]]; then
        printf '%s\n' "${source_url}"
        return
      fi
      repo="$(jq -r '.repo // ""' <<<"${item_json}")"
      [[ -n "${repo}" ]] && printf 'https://github.com/%s\n' "${repo}"
      ;;
    apple_app_store|page_metadata)
      url="$(jq -r '.url // ""' <<<"${item_json}")"
      [[ -n "${url}" ]] && printf '%s\n' "${url}"
      ;;
    *)
      ;;
  esac
}

build_github_release_tag_url() {
  local repo="$1"
  local version="$2"
  [[ -z "${repo}" || -z "${version}" || "${version}" == "N/A" ]] && return
  local encoded_version
  encoded_version="$("${PYTHON_BIN}" - "${version}" <<'PY'
from urllib.parse import quote
import sys
print(quote(sys.argv[1], safe=""))
PY
)"
  printf 'https://github.com/%s/releases/tag/%s\n' "${repo}" "${encoded_version}"
}

write_group_table() {
  local group_json="$1"
  local output_file="$2"
  local group_name items_file group_key existing_rows_file
  group_name="$(jq -r '.title' <<<"${group_json}")"
  group_key="$(jq -r '.key' <<<"${group_json}")"
  items_file="${TMP_DIR}/${group_key}_items.jsonl"
  existing_rows_file="${TMP_DIR}/${group_key}_existing.jsonl"
  : > "${items_file}"
  extract_existing_group_rows "${group_json}" "${existing_rows_file}"

  local index=1
  while IFS= read -r item_json; do
    [[ -z "${item_json}" ]] && continue
    local source_type result_json name version updated_at download_url asset_name source_url status metadata_only fetch_status item_name existing_row proxy_page_url
    source_type="$(jq -r '.type' <<<"${item_json}")"
    item_name="$(jq -r '.name' <<<"${item_json}")"
    proxy_page_url=""
    result_json=""
    fetch_status=0
    set +e
    case "${source_type}" in
      github_apk)
        result_json="$(fetch_github_release_item "${item_json}" "github_apk")"
        fetch_status=$?
        ;;
      github_asset)
        result_json="$(fetch_github_release_item "${item_json}" "github_asset")"
        fetch_status=$?
        ;;
      direct)
        result_json="$(fetch_direct_item "${item_json}")"
        fetch_status=$?
        ;;
      mt_manager_t28)
        result_json="$(fetch_mt_item "${item_json}")"
        fetch_status=$?
        ;;
      telegram_lsposed)
        result_json="$(fetch_telegram_lsposed_item "${item_json}")"
        fetch_status=$?
        ;;
      github_proxy)
        result_json="$(fetch_github_proxy_item "${item_json}")"
        fetch_status=$?
        ;;
      apple_app_store)
        result_json="$(fetch_apple_app_store_item "${item_json}")"
        fetch_status=$?
        ;;
      page_metadata)
        result_json="$(fetch_page_metadata_item "${item_json}")"
        fetch_status=$?
        ;;
      static_metadata)
        result_json="$(fetch_static_metadata_item "${item_json}")"
        fetch_status=$?
        ;;
      *)
        result_json="$(jq -n --arg name "${item_name}" --arg type "${source_type}" '{ok:false,name:$name,version:"N/A",updated_at:"",download_url:"",asset_name:"",source_url:"",error:("Unsupported source type: " + $type)}')"
        fetch_status=0
        ;;
    esac
    set -e

    if [[ "${fetch_status}" -ne 0 || -z "${result_json}" ]] || ! jq -e . >/dev/null 2>&1 <<<"${result_json}"; then
      result_json="$(jq -n \
        --arg name "${item_name}" \
        --arg type "${source_type}" \
        --arg error "Fetcher exited with status ${fetch_status}" \
        '{ok:false,name:$name,version:"N/A",updated_at:"",download_url:"",asset_name:"",source_url:"",error:($type + ": " + $error)}')"
    fi

    existing_row="$(jq -c --arg name "${item_name}" 'select(.name == $name)' "${existing_rows_file}" | head -n 1)"
    status="$(jq -r '.ok' <<<"${result_json}")"
    name="$(jq -r '.name' <<<"${result_json}")"
    version="$(jq -r '.version // "N/A"' <<<"${result_json}")"
    updated_at="$(jq -r '.updated_at // ""' <<<"${result_json}")"
    download_url="$(jq -r '.download_url // ""' <<<"${result_json}")"
    asset_name="$(jq -r '.asset_name // ""' <<<"${result_json}")"
    source_url="$(jq -r '.source_url // ""' <<<"${result_json}")"
    metadata_only="$(jq -r '.metadata_only // false' <<<"${result_json}")"
    if [[ "${group_key}" == "proxy_clients" ]]; then
      proxy_page_url="$(resolve_proxy_item_page_url "${item_json}")"
      [[ -z "${source_url}" && -n "${proxy_page_url}" ]] && source_url="${proxy_page_url}"
    fi

    if [[ "${status}" != "true" && -n "${existing_row}" ]]; then
      log "Preserving existing ${group_name}: ${item_name}"
      if [[ "${group_key}" == "proxy_clients" && -n "${proxy_page_url}" ]]; then
        local preserve_source_url repo release_tag_url existing_version
        preserve_source_url="${proxy_page_url}"
        if [[ "${source_type}" == "github_proxy" ]]; then
          repo="$(jq -r '.repo // ""' <<<"${item_json}")"
          existing_version="$(jq -r '.version // "N/A"' <<<"${existing_row}")"
          release_tag_url="$(build_github_release_tag_url "${repo}" "${existing_version}")"
          [[ -n "${release_tag_url}" ]] && preserve_source_url="${release_tag_url}"
        fi
        jq -nc \
          --argjson index "${index}" \
          --argjson existing "${existing_row}" \
          --arg source_url "${preserve_source_url}" \
          '{
            index: $index,
            name: $existing.name,
            version: $existing.version,
            updated_at: $existing.updated_at,
            download_label: "",
            download_url: "",
            source_url: $source_url,
            status: "true"
          }' >> "${items_file}"
      else
        jq -nc \
          --argjson index "${index}" \
          --argjson existing "${existing_row}" \
          '{
            index: $index,
            name: $existing.name,
            version: $existing.version,
            updated_at: $existing.updated_at,
            download_label: $existing.download_label,
            download_url: $existing.download_url,
            source_url: $existing.source_url,
            status: ($existing.status | tostring)
          }' >> "${items_file}"
      fi
      index=$((index + 1))
      continue
    fi

    if [[ "${group_key}" == "proxy_clients" && "${status}" != "true" && -n "${proxy_page_url}" ]]; then
      log "Falling back to source page for ${group_name}: ${item_name}"
      jq -nc \
        --argjson index "${index}" \
        --arg name "${item_name}" \
        --arg version "${version:-N/A}" \
        --arg updated_at "${updated_at:-N/A}" \
        --arg source_url "${proxy_page_url}" \
        '{
          index: $index,
          name: $name,
          version: ($version | if . == "" then "N/A" else . end),
          updated_at: ($updated_at | if . == "" then "N/A" else . end),
          download_label: "",
          download_url: "",
          source_url: $source_url,
          status: "true"
        }' >> "${items_file}"
      index=$((index + 1))
      continue
    fi

    if [[ "${status}" == "true" && "${metadata_only}" != "true" && -n "${download_url}" ]]; then
      local download_dir filename safe_name
      download_dir="${DOWNLOAD_ROOT}/$(jq -r '.output_dir' <<<"${group_json}")"
      mkdir -p "${download_dir}"
      if [[ "${SKIP_DOWNLOADS}" == "1" ]]; then
        log "Skipping binary download for ${group_name}: ${name} (SKIP_DOWNLOADS=1)"
      else
        safe_name="$(sanitize_filename "${name}")"
        filename="${download_dir}/${safe_name}__${asset_name}"
        log "Downloading ${group_name}: ${name}"
        download_file "${download_url}" "${filename}"
      fi
    elif [[ "${status}" == "true" && "${metadata_only}" == "true" ]]; then
      log "Resolved ${group_name}: ${name} (metadata only)"
    else
      log "Skipping download for ${name}: $(jq -r '.error // "unknown error"' <<<"${result_json}")"
    fi

    jq -nc \
      --argjson index "${index}" \
      --arg name "${name}" \
      --arg version "${version}" \
      --arg updated_at "${updated_at:-N/A}" \
      --arg download_label "${asset_name:-下载}" \
      --arg download_url "${download_url}" \
      --arg source_url "${source_url}" \
      --arg status "${status}" \
      '{
        index: $index,
        name: $name,
        version: ($version | if . == "" then "N/A" else . end),
        updated_at: ($updated_at | if . == "" then "N/A" else . end),
        download_label: ($download_label | if . == "" then "下载" else . end),
        download_url: $download_url,
        source_url: $source_url,
        status: $status
      }' >> "${items_file}"

    index=$((index + 1))
  done < <(iterate_group_items "${group_json}")

  {
    echo "| 序号 | 软件名 | 版本 | 更新时间 | 下载链接 |"
    echo "| --- | --- | --- | --- | --- |"
    while IFS= read -r row; do
      [[ -z "${row}" ]] && continue
      local row_index row_name row_version row_updated row_label row_url row_source row_status link
      row_index="$(jq -r '.index' <<<"${row}")"
      row_name="$(jq -r '.name' <<<"${row}")"
      row_version="$(jq -r '.version' <<<"${row}")"
      row_updated="$(jq -r '.updated_at' <<<"${row}")"
      row_label="$(jq -r '.download_label' <<<"${row}")"
      row_url="$(jq -r '.download_url' <<<"${row}")"
      row_source="$(jq -r '.source_url' <<<"${row}")"
      row_status="$(jq -r '.status' <<<"${row}")"
      if [[ "${group_key}" == "proxy_clients" && "${row_status}" == "true" && ( -n "${row_source}" || -n "${row_url}" ) ]]; then
        if [[ -n "${row_source}" ]]; then
          link="$(format_markdown_link "前往下载" "${row_source}")"
        else
          link="$(format_markdown_link "前往下载" "${row_url}")"
        fi
      elif [[ "${row_status}" == "true" && -n "${row_url}" ]]; then
        link="$(format_markdown_link "${row_label}" "${row_url}")"
      elif [[ -n "${row_source}" ]]; then
        link="$(format_markdown_link "查看来源" "${row_source}")"
      else
        link="获取失败"
      fi
      echo "| ${row_index} | ${row_name} | ${row_version} | ${row_updated} | ${link} |"
    done < "${items_file}"
  } > "${output_file}"
}

replace_section() {
  local file="$1"
  local start_marker="$2"
  local end_marker="$3"
  local content_file="$4"
  "${PYTHON_BIN}" - "$file" "$start_marker" "$end_marker" "$content_file" <<'PY'
from pathlib import Path
import sys

file_path = Path(sys.argv[1])
start = sys.argv[2]
end = sys.argv[3]
content = Path(sys.argv[4]).read_text(encoding="utf-8").rstrip()
text = file_path.read_text(encoding="utf-8")

start_index = text.find(start)
end_index = text.find(end)
if start_index == -1 or end_index == -1 or end_index < start_index:
    raise SystemExit(f"Marker not found in {file_path}: {start} / {end}")

start_index += len(start)
new_text = text[:start_index] + "\n" + content + "\n" + text[end_index:]
file_path.write_text(new_text, encoding="utf-8")
PY
}

main() {
  local group_json group_key table_file output_dir start_marker end_marker

  while IFS= read -r group_json; do
    [[ -z "${group_json}" ]] && continue
    output_dir="${DOWNLOAD_ROOT}/$(jq -r '.output_dir' <<<"${group_json}")"
    rm -rf "${output_dir}"
    mkdir -p "${output_dir}"
  done < <(jq -c '.groups[]' "${CONFIG_FILE}")

  while IFS= read -r group_json; do
    [[ -z "${group_json}" ]] && continue
    group_key="$(jq -r '.key' <<<"${group_json}")"
    table_file="${TMP_DIR}/${group_key}_table.md"
    start_marker="$(jq -r '.start_marker' <<<"${group_json}")"
    end_marker="$(jq -r '.end_marker' <<<"${group_json}")"

    write_group_table "${group_json}" "${table_file}"
    replace_section "${README_FILE}" "${start_marker}" "${end_marker}" "${table_file}"
  done < <(jq -c '.groups[]' "${CONFIG_FILE}")

  log "README.md updated."
}

main "$@"
