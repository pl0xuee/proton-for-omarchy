#!/usr/bin/env bash
# Static security invariants from PLAN.md §7. Exits non-zero on any violation.
set -u
cd "$(dirname "$0")/.."
fail=0
bad() { echo "FAIL: $*"; fail=1; }

qml_files=$(ls ./*.qml components/*.qml)
py_files=$(ls backend/*.py)

# 1. No raw Text elements: PlainText (or kit components that force PlainText).
for f in $qml_files; do
  [ "$f" = "components/PlainText.qml" ] && continue
  # A raw Text is fine only if it pins textFormat: Text.PlainText itself.
  if ! awk '/^[[:space:]]*Text[[:space:]]*\{/ { open=1; ok=0; depth=0 }
            open { depth += gsub(/\{/, "{"); depth -= gsub(/\}/, "}");
                   if ($0 ~ /textFormat:[[:space:]]*Text\.PlainText/) ok=1;
                   if (depth <= 0) { if (!ok) bad=1; open=0 } }
            END { exit bad }' "$f"; then bad "$f has a Text element without textFormat: Text.PlainText"; fi
done
grep -q 'textFormat: Text.PlainText' components/PlainText.qml || bad "PlainText.qml does not force Text.PlainText"
if grep -nE 'Text\.(RichText|StyledText|MarkdownText|AutoText)' $qml_files; then bad "rich text format used"; fi

# 1b. Theme-bound visuals: no hex colors, no bare animation durations.
if grep -nE '"#[0-9a-fA-F]{3,8}"' $qml_files; then bad "hardcoded hex color in QML"; fi
if grep -nE 'duration:\s*[0-9]' $qml_files; then bad "bare numeric animation duration (use Style.duration)"; fi

# 2. No shell interpolation anywhere.
if grep -nE '"(ba)?sh"\s*,\s*"-c"|bash -c|sh -c' $qml_files $py_files; then bad "shell -c invocation"; fi
if grep -nE 'shell\s*=\s*True|os\.system\(|os\.popen\(' $py_files; then bad "python shell execution"; fi

# 3. notify-send always terminates options with --.
if grep -q '"notify-send"' Service.qml && ! grep -q 'args.push("--"' Service.qml; then bad "notify-send without -- terminator"; fi

# 4. Clipboard only via wl-copy -- on stdin from the bridge.
if grep -nE 'wl-copy' $qml_files; then bad "QML calls wl-copy directly"; fi
grep -q 'exe, "--", stdin=asyncio.subprocess.PIPE' backend/bridge.py || bad "bridge wl-copy not using -- and stdin"

# 5. No third-party IP lookup services.
if grep -rniE 'ipinfo|ip-api|ifconfig\.(me|co)|icanhazip|ipify|myip' $qml_files $py_files; then bad "third-party IP lookup"; fi

# 6. Secrets never in argv/env/logs.
if grep -nE 'argv.*(password|totp|pin)|environ\[.*(PASS|TOKEN)' $py_files; then bad "secret in argv/env"; fi
grep -q 'REDACT' backend/protocol.py || grep -q 'redact' backend/*.py || bad "no redaction in backend"

# 7. Plugin folder hygiene.
if find . -path ./.git -prune -o -type l -print | grep -q .; then bad "symlinks present"; fi
python3 - <<'PY' || fail=1
import json, sys
m = json.load(open("manifest.json"))
if m["id"].startswith("omarchy."):
    print("FAIL: plugin id must not start with omarchy."); sys.exit(1)
PY

# 8. State files written atomically with 0600.
grep -q '0o600' backend/profiles.py || bad "profiles not written with 0600"
grep -q 'os.replace' backend/profiles.py || bad "profiles not written atomically"

[ $fail -eq 0 ] && echo "qml/backend safety checks: OK"
exit $fail
