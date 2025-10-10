#!/usr/bin/env bash
set -euo pipefail
REPO_NAME="${1:-harmoniq}"
DEFAULT_VISIBILITY="${2:-public}"

if ! command -v git >/dev/null; then echo "git missing"; exit 1; fi
[ -d .git ] || git init
git rev-parse HEAD >/dev/null 2>&1 || { git add .; git commit -m "Initial commit"; }

if command -v gh >/dev/null && ! git remote get-url origin >/dev/null 2>&1; then
  USER="$(gh api user --jq .login)"
  gh repo create "$USER/$REPO_NAME" --$DEFAULT_VISIBILITY --source=. --remote=origin --push
fi

mkdir -p .github/workflows .github/ISSUE_TEMPLATE test

cat > .github/workflows/flutter-ci.yml <<'YML'
name: Flutter CI
on:
  pull_request:
  push:
    branches: [ main, develop ]
jobs:
  format-analyze-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with: { channel: stable }
      - run: flutter pub get
      - run: flutter format --set-exit-if-changed .
      - run: flutter analyze --no-pub
      - run: flutter test --reporter expanded
  android-build:
    runs-on: ubuntu-latest
    needs: format-analyze-test
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with: { channel: stable }
      - run: flutter pub get
      - run: flutter build apk --release
      - uses: actions/upload-artifact@v4
        with:
          name: app-release-apk
          path: build/app/outputs/flutter-apk/app-release.apk
YML

cat > .github/PULL_REQUEST_TEMPLATE.md <<'MD'
## Summary
Short description.

## Tests
- [ ] Ran on iPhone/Android
- [ ] Compared BPM/Key vs ground truth

## Notes
Focus areas for reviewers.
MD

cat > .github/labeler.yml <<'LBL'
bpm: [lib/bpm_estimator.dart]
key: [lib/key_detector.dart]
offline: [lib/offline_file_analyzer_page.dart]
ui: [lib/analyzer_page.dart]
LBL

GH_USER="$(git config user.name || echo user)"
cat > CODEOWNERS <<EOF2
* @$GH_USER
EOF2

cat > test/bpm_estimator_test.dart <<'DART'
import 'package:test/test.dart';
import 'package:harmoniq/bpm_estimator.dart';
void main() => test('init', () => expect(BpmEstimator().bpm, anyOf(isNull, greaterThan(0))));
DART

git add .github CODEOWNERS test || true
git commit -m "Setup CI & templates" || true
git branch -M main || true
git push -u origin main || true

cat <<MSG
✅ Done!

Next:
1. Go to https://github.com/settings/installations and install the Anthropic Claude GitHub App on this repo.
2. In Claude settings → enable Repo Tracking → add watched paths:
   lib/bpm_estimator.dart
   lib/key_detector.dart
   lib/offline_file_analyzer_page.dart
   lib/analyzer_page.dart
   ios/ android/ .github/
3. Start a branch:
   git checkout -b feature/test
   echo "ok" >> README.md
   git commit -am "test"
   git push -u origin feature/test
MSG
