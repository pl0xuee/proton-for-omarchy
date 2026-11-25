#!/usr/bin/env python3
"""Check every i18n/<lang>.json against i18n/en.json.

- only known keys (no typos or stale keys)
- the same %1/%2 placeholders as English
- plural entries are objects with an "other" form; plain entries are strings
- no markup characters that would only make sense as rich text
Missing keys are allowed (they fall back to English) but reported.
"""

from __future__ import annotations

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
I18N = os.path.join(ROOT, "i18n")
PLACEHOLDER = re.compile(r"%\d")
PLURAL_FORMS = {"zero", "one", "two", "few", "many", "other"}


def placeholders(value) -> set[str]:
    texts = value.values() if isinstance(value, dict) else [value]
    return {p for t in texts for p in PLACEHOLDER.findall(str(t))}


def main() -> int:
    with open(os.path.join(I18N, "en.json"), encoding="utf-8") as fh:
        english = json.load(fh)
    failed = False
    for name in sorted(os.listdir(I18N)):
        if not name.endswith(".json") or name == "en.json":
            continue
        with open(os.path.join(I18N, name), encoding="utf-8") as fh:
            catalog = json.load(fh)
        problems = []
        for key, value in catalog.items():
            if key not in english:
                problems.append(f"unknown key {key}")
                continue
            plural = isinstance(english[key], dict)
            if plural:
                if not isinstance(value, dict) or "other" not in value or not set(value) <= PLURAL_FORMS:
                    problems.append(f"{key}: plural entry needs CLDR forms with 'other'")
                    continue
                if not all(isinstance(v, str) and v for v in value.values()):
                    problems.append(f"{key}: empty plural form")
            elif not isinstance(value, str) or not value.strip():
                problems.append(f"{key}: must be a non-empty string")
                continue
            if placeholders(value) != placeholders(english[key]):
                problems.append(f"{key}: placeholders {sorted(placeholders(value))} != {sorted(placeholders(english[key]))}")
            texts = value.values() if isinstance(value, dict) else [value]
            if any("<" in t and ">" in t for t in texts):
                problems.append(f"{key}: looks like markup")
        missing = len(set(english) - set(catalog))
        status = "FAIL" if problems else "ok"
        print(f"{name}: {status}, {len(catalog)} strings, {missing} missing")
        for p in problems:
            print("   ", p)
        failed |= bool(problems)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
