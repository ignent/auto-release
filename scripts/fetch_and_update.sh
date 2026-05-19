#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
README_FILE="${ROOT_DIR}/README.md"
CONFIG_FILE="${ROOT_DIR}/sources.json"
DOWNLOAD_ROOT="${ROOT_DIR}/releases"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

log() {
  printf '[fetch] %s\n' "$*"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

require_command curl
require_command jq
require_command python3

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
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

fetch_json() {
  curl --fail --location --silent --show-error --retry 3 "$1"
}

fetch_text() {
  curl --fail --location --silent --show-error --retry 3 "$1"
}

sanitize_filename() {
  python3 - "$1" <<'PY'
import re
import sys
print(re.sub(r'[\\/:*?"<>|]+', "_", sys.argv[1]))
PY
}

extract_filename_from_url() {
  python3 - "$1" <<'PY'
from urllib.parse import urlparse, unquote
import os
import sys
path = urlparse(sys.argv[1]).path
name = os.path.basename(path.rstrip("/"))
print(unquote(name))
PY
}

parse_last_modified_to_iso() {
  python3 - "$1" <<'PY'
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
    PAGE_HTML_FILE="${page_html_file}" python3 <<'PY'
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
  fdroid_html="$(fetch_text "${fdroid_url}")"
  fdroid_html_file="$(mktemp "${TMP_DIR}/antennapod-fdroid.XXXXXX.html")"
  printf '%s' "${fdroid_html}" > "${fdroid_html_file}"

  FDROID_HTML_FILE="${fdroid_html_file}" FDROID_URL="${fdroid_url}" python3 <<'PY'
from html.parser import HTMLParser
from urllib.parse import urljoin
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
        self.current_classes = ""
        self.current_href = None
        self.current_text = []
        self.current_item = None

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
        self.current_classes = classes
        if tag == "a":
          self.current_href = attrs_dict.get("href")
          self.current_text = []

    def handle_data(self, data):
        if not self.capture_li:
          return
        text = data.strip()
        if not text:
          return
        if "package-version-header" in self.current_classes:
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
        if tag == "li":
          self.li_depth -= 1
          if self.li_depth == 0:
            self.items.append(self.current_item)
            self.current_item = None
            self.capture_li = False
        self.current_classes = ""

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
    "updated_at": "",
    "download_url": apk_url,
    "asset_name": apk_name,
    "page_url": page_url
}, ensure_ascii=False))
PY
}

fetch_github_release_item() {
  local item_json="$1"
  local mode="$2"
  local name repo api_url response tag_name published_at html_url release_name extensions preferred avoid
  name="$(jq -r '.name' <<<"${item_json}")"
  repo="$(jq -r '.repo' <<<"${item_json}")"
  api_url="https://api.github.com/repos/${repo}/releases/latest"
  response="$(fetch_json "${api_url}")"
  tag_name="$(jq -r '.tag_name // .name // "N/A"' <<<"${response}")"
  published_at="$(jq -r '.published_at // ""' <<<"${response}")"
  html_url="$(jq -nr --arg repo "${repo}" --argjson data "${response}" '$data.html_url // ("https://github.com/" + $repo + "/releases/latest")')"
  release_name="$(jq -r '.name // ""' <<<"${response}")"
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
    --arg download_url "${effective_url:-${url}}" \
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

  PAGE_HTML_FILE="${html_file}" PAGE_URL="${page_url}" ITEM_NAME="${name}" python3 <<'PY'
from html.parser import HTMLParser
from urllib.parse import urljoin
import json
import os
import re
import urllib.request

with open(os.environ["PAGE_HTML_FILE"], "r", encoding="utf-8") as fp:
    html = fp.read()
page_url = os.environ["PAGE_URL"]
item_name = os.environ["ITEM_NAME"]
text = re.sub(r"<[^>]+>", "\n", html)
version_match = re.search(r"版本名[:：]\s*(v[^\s]+)", text)
date_match = re.search(r"发布时间[:：]\s*([0-9]{4}-[0-9]{2}-[0-9]{2})", text)
version = version_match.group(1) if version_match else "N/A"
updated_at = date_match.group(1) if date_match else ""

keywords = ("本地下载（正式版 TargetSdk28）", "正式版 TargetSdk28", "正式版 T28", "TargetSdk28")

class Parser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.current_href = None
        self.buffer = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.current_href = dict(attrs).get("href")
            self.buffer = []

    def handle_data(self, data):
        if self.current_href is not None:
            self.buffer.append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self.current_href is not None:
            text = "".join(self.buffer).strip()
            self.links.append((text, self.current_href))
            self.current_href = None
            self.buffer = []

parser = Parser()
parser.feed(html)

candidates = []
for text_value, href in parser.links:
    if any(keyword in text_value for keyword in keywords):
        score = 0
        if "正式版" in text_value:
            score += 50
        if "TargetSdk28" in text_value:
            score += 40
        if "本地下载" in text_value:
            score += 10
        if "共存" in text_value:
            score -= 100
        candidates.append((score, text_value, urljoin(page_url, href)))

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
    raise SystemExit

candidates.sort(key=lambda item: item[0], reverse=True)
_, _, entry_url = candidates[0]
request = urllib.request.Request(entry_url, headers={"User-Agent": "Mozilla/5.0"})
with urllib.request.urlopen(request, timeout=60) as response:
    final_url = response.geturl()
asset_name = final_url.rstrip("/").split("/")[-1] or "MTManager.apk"

print(json.dumps({
    "ok": True,
    "name": item_name,
    "version": version,
    "updated_at": updated_at,
    "download_url": final_url,
    "asset_name": asset_name,
    "source_url": page_url
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

  PAGE_HTML_FILE="${html_file}" PAGE_URL="${page_url}" ITEM_NAME="${name}" python3 <<'PY'
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
    print(json.dumps({
        "ok": True,
        "name": item_name,
        "version": asset_name,
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

format_markdown_link() {
  local label="$1"
  local url="$2"
  printf '[%s](%s)' "${label}" "${url}"
}

write_group_table() {
  local group_json="$1"
  local output_file="$2"
  local group_name items_file
  group_name="$(jq -r '.title' <<<"${group_json}")"
  items_file="${TMP_DIR}/items.jsonl"
  : > "${items_file}"

  local index=1
  while IFS= read -r item_json; do
    [[ -z "${item_json}" ]] && continue
    local source_type result_json name version updated_at download_url asset_name source_url status metadata_only
    source_type="$(jq -r '.type' <<<"${item_json}")"
    case "${source_type}" in
      github_apk)
        result_json="$(fetch_github_release_item "${item_json}" "github_apk")"
        ;;
      github_asset)
        result_json="$(fetch_github_release_item "${item_json}" "github_asset")"
        ;;
      direct)
        result_json="$(fetch_direct_item "${item_json}")"
        ;;
      mt_manager_t28)
        result_json="$(fetch_mt_item "${item_json}")"
        ;;
      telegram_lsposed)
        result_json="$(fetch_telegram_lsposed_item "${item_json}")"
        ;;
      *)
        result_json="$(jq -n --arg name "$(jq -r '.name' <<<"${item_json}")" --arg type "${source_type}" '{ok:false,name:$name,version:"N/A",updated_at:"",download_url:"",asset_name:"",source_url:"",error:("Unsupported source type: " + $type)}')"
        ;;
    esac

    status="$(jq -r '.ok' <<<"${result_json}")"
    name="$(jq -r '.name' <<<"${result_json}")"
    version="$(jq -r '.version // "N/A"' <<<"${result_json}")"
    updated_at="$(jq -r '.updated_at // ""' <<<"${result_json}")"
    download_url="$(jq -r '.download_url // ""' <<<"${result_json}")"
    asset_name="$(jq -r '.asset_name // ""' <<<"${result_json}")"
    source_url="$(jq -r '.source_url // ""' <<<"${result_json}")"
    metadata_only="$(jq -r '.metadata_only // false' <<<"${result_json}")"

    if [[ "${status}" == "true" && "${metadata_only}" != "true" && -n "${download_url}" ]]; then
      local download_dir filename safe_name
      download_dir="${DOWNLOAD_ROOT}/$(jq -r '.output_dir' <<<"${group_json}")"
      mkdir -p "${download_dir}"
      safe_name="$(sanitize_filename "${name}")"
      filename="${download_dir}/${safe_name}__${asset_name}"
      log "Downloading ${group_name}: ${name}"
      download_file "${download_url}" "${filename}"
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
  done < <(jq -c '.items[]' <<<"${group_json}")

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
      if [[ "${row_status}" == "true" && -n "${row_url}" ]]; then
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
  python3 - "$file" "$start_marker" "$end_marker" "$content_file" <<'PY'
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
  local apk_table="${TMP_DIR}/apk_table.md"
  local module_table="${TMP_DIR}/module_table.md"

  rm -rf "${DOWNLOAD_ROOT}/apks" "${DOWNLOAD_ROOT}/modules"
  mkdir -p "${DOWNLOAD_ROOT}/apks" "${DOWNLOAD_ROOT}/modules"

  write_group_table "$(jq -c '.groups[] | select(.key == "apks")' "${CONFIG_FILE}")" "${apk_table}"
  write_group_table "$(jq -c '.groups[] | select(.key == "modules")' "${CONFIG_FILE}")" "${module_table}"

  replace_section "${README_FILE}" "<!-- APK_TABLE_START -->" "<!-- APK_TABLE_END -->" "${apk_table}"
  replace_section "${README_FILE}" "<!-- MODULE_TABLE_START -->" "<!-- MODULE_TABLE_END -->" "${module_table}"

  log "README.md updated."
}

main "$@"
