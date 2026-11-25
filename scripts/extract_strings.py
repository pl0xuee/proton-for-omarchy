#!/usr/bin/env python3
"""Regenerate i18n/en.json from the t("key", "fallback") calls in the QML.

The English fallbacks in the code are the source of truth; this keeps the
catalog in sync so translators have a complete list. Plural strings come from
tn("key", count, "fallback") and get a hand-maintained singular form below.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
T_CALL = re.compile(r'\bt\(\s*"([A-Za-z0-9_.]+)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)')
TN_CALL = re.compile(r'\btn\(\s*"([A-Za-z0-9_.]+)"\s*,[^,]+,\s*"((?:[^"\\]|\\.)*)"\s*\)')
SINGULAR = {
    "servers.cityCount": "%1 city",
    "servers.serverCount": "%1 server",
    "split.appCount": "%1 app",
    "split.ipCount": "%1 IP",
    "account.devices": "Up to %1 device",
}


def unescape(s: str) -> str:
    return json.loads('"' + s + '"')


def main() -> int:
    strings: dict = {}
    conflicts = []
    files = sorted(list(ROOT.glob("*.qml")) + list(ROOT.glob("components/*.qml")))
    for path in files:
        text = path.read_text(encoding="utf-8")
        for key, fallback in T_CALL.findall(text):
            value = unescape(fallback)
            if key in strings and strings[key] != value:
                conflicts.append(f"{path.name}: {key!r}: {strings[key]!r} vs {value!r}")
                continue
            strings[key] = value
        for key, fallback in TN_CALL.findall(text):
            strings[key] = {"one": SINGULAR.get(key, unescape(fallback)), "other": unescape(fallback)}
    if conflicts:
        print("Conflicting fallbacks:\n  " + "\n  ".join(conflicts), file=sys.stderr)
        return 1
    out = ROOT / "i18n" / "en.json"
    out.write_text(json.dumps(dict(sorted(strings.items())), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {len(strings)} strings to {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
