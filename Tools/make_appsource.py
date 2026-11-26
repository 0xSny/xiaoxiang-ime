#!/usr/bin/env python3
"""Maintains the AltStore / 全能签 compatible static source (apps.json) served by GitHub Pages.

Usage: make_appsource.py --repo owner/name --version 1.0.5 --build 5 --ipa CustomIME.ipa
                         --notes "text" --out pages/apps.json [--validate URL]
"""
import argparse
import json
import os
import sys
import urllib.request
from datetime import datetime, timezone

BUNDLE_ID = "com.custom.ime"
APP_NAME = "小象输入法"


def build(args):
    owner, name = args.repo.split("/")
    pages = f"https://{owner}.github.io/{name}"
    release = f"https://github.com/{args.repo}/releases/download/v{args.version}/{os.path.basename(args.ipa)}"
    size = os.path.getsize(args.ipa)
    date = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    entry = {
        "version": args.version,
        "buildVersion": str(args.build),
        "date": date,
        "localizedDescription": args.notes,
        "downloadURL": release,
        "size": size,
        "minOSVersion": "16.0",
    }
    existing = {}
    if os.path.exists(args.out):
        try:
            with open(args.out, encoding="utf-8") as fh:
                existing = json.load(fh)
        except Exception:
            existing = {}
    versions = []
    for app in existing.get("apps", []):
        if app.get("bundleIdentifier") == BUNDLE_ID:
            versions = [v for v in app.get("versions", []) if v.get("version") != args.version]
    versions.insert(0, entry)
    versions = versions[:12]
    app = {
        "name": APP_NAME,
        "bundleIdentifier": BUNDLE_ID,
        "developerName": owner,
        "subtitle": "纯本地离线 · 全拼 + 小鹤双拼",
        "localizedDescription": "纯自研 C++17 解码引擎的 iOS 中文输入法：全拼 / 小鹤双拼、空间概率纠错、本地自学习，零联网零隐私上传。",
        "iconURL": f"{pages}/icon.png",
        "tintColor": "3D7BEA",
        "category": "utilities",
        "screenshotURLs": [],
        # legacy flat fields (older AltStore-style readers) mirror the newest version
        "version": entry["version"],
        "versionDate": entry["date"],
        "versionDescription": entry["localizedDescription"],
        "downloadURL": entry["downloadURL"],
        "size": entry["size"],
        "versions": versions,
        "appPermissions": {"entitlements": [], "privacy": {}},
    }
    return {
        "name": "小象输入法软件源",
        "subtitle": "小象输入法自动更新源",
        "description": "每次云端构建成功后自动更新的未签名 IPA 软件源。",
        "iconURL": f"{pages}/icon.png",
        "website": f"https://github.com/{args.repo}",
        "tintColor": "3D7BEA",
        "identifier": "com.custom.ime.source",
        "sourceURL": f"{pages}/apps.json",
        "apps": [app],
        "news": [],
    }


def validate(doc, url):
    assert doc["apps"][0]["bundleIdentifier"] == BUNDLE_ID
    v = doc["apps"][0]["versions"][0]
    assert v["size"] > 1_000_000, "ipa too small"
    for key in ("version", "buildVersion", "date", "downloadURL", "size"):
        assert v.get(key), key
    print("source document valid:", v["version"], v["size"], "bytes")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--build", required=True)
    ap.add_argument("--ipa", required=True)
    ap.add_argument("--notes", default="")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    doc = build(args)
    validate(doc, None)
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print("wrote", args.out)


if __name__ == "__main__":
    sys.exit(main())
