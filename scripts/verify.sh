#!/usr/bin/env bash
# Full local verification: Python + JS unit tests, static safety audit,
# qmllint (when available) and the Omarchy plugin validator.
set -u
cd "$(dirname "$0")/.."
status=0
step() { printf '\n== %s\n' "$*"; }

step "Python unit tests"
python3 -m unittest discover -s tests -p "test_*.py" || status=1

step "Model.js tests"
if command -v node >/dev/null; then node --test tests/test_model.mjs || status=1
else echo "node not installed; skipped"; fi

step "Static safety audit"
bash tests/test_qml_safety.sh || status=1

step "qmllint"
QMLLINT=$(command -v qmllint6 || command -v qmllint || echo /usr/lib/qt6/bin/qmllint)
SHELL_DIR=/usr/share/omarchy/shell
if [ -x "$QMLLINT" ] && [ -d "$SHELL_DIR" ]; then
  root=$(mktemp -d)
  ln -s "$SHELL_DIR" "$root/qs"   # import path shim, outside the repo
  out=$("$QMLLINT" -I "$root" ./*.qml components/*.qml 2>&1 \
    | grep -E '^(Warning|Error)' \
    | grep -vE 'on type "QObject"|\[unqualified\]|\[import\]' || true)
  rm -rf "$root"
  if [ -n "$out" ]; then echo "$out"; status=1; else echo "qmllint: clean"; fi
else
  echo "qmllint or Omarchy shell not found; skipped"
fi

step "Translation catalog in sync"
before=$(sha1sum i18n/en.json)
python3 scripts/extract_strings.py >/dev/null || status=1
[ "$before" = "$(sha1sum i18n/en.json)" ] && echo "i18n/en.json: up to date" || { echo "i18n/en.json was stale (regenerated)"; status=1; }

step "Omarchy plugin validator"
if command -v omarchy-plugin-validate >/dev/null; then omarchy-plugin-validate . || status=1
elif [ -x /usr/share/omarchy/bin/omarchy-plugin-validate ]; then /usr/share/omarchy/bin/omarchy-plugin-validate . || status=1
else echo "validator not found; skipped"; fi

echo
[ $status -eq 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $status
