#!/bin/bash
# 설정 화면 규칙 검사 / Settings screen rule check (docs/ARCHITECTURE.md "설정 화면 규칙")
# 페이지(Settings/Pages)는 SettingsComponents.swift의 부품만 써서 같은 종류의 값을 같은 방식으로 고르게 한다.
# Pages must use the shared components so similar options are chosen the same way everywhere.
cd "$(dirname "$0")/.."
PAGES=Sources/DynamicMacNotch/Settings/Pages
fail=0
check() {   # 설명, 패턴
  local hits
  hits=$(grep -nE "$2" "$PAGES"/*.swift)
  if [ -n "$hits" ]; then
    echo "settings UI rule: $1" >&2
    echo "$hits" | sed 's/^/  /' >&2
    fail=1
  fi
}
check "use Choice / ListChoice / ChoiceMenu instead of Picker" '(^|[^A-Za-z])Picker\('
check "the components set the picker style" '\.pickerStyle\('
check "use ValueSlider instead of Slider" '(^|[^A-Za-z])Slider\('
check "use ValueMenu with a Choices list instead of Stepper" '(^|[^A-Za-z])Stepper\('
check "put value lists in Choices (SettingsComponents.swift)" 'values: *\['
check "use Format.percent" '\* *100\)\.rounded'
# 글 길이: 줄 이름 14자, 보조 설명·구역 설명 60자 (한국어 기준, \(…) 끼워 넣기는 빼고 셈). 긴 설명은 more:로
# Text length: row names 14, details and footers 60 (Korean; interpolations not counted). Longer text goes in more:
/usr/bin/python3 -I - "$PAGES" <<'PY' || fail=1
import re, sys, glob
TP = r'T\("((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)"\)'
KIND = r'(Toggle\(|HomePageToggle\([^)]*?title: |footer: |detail: |ValueMenu\(title: |ValueSlider\(title: |Choice\(|ListChoice\(|ListField\(title: |FolderSetting\(title: )'
bad = []
for p in sorted(glob.glob(sys.argv[1] + "/*.swift")):
    s = open(p, encoding="utf-8").read()
    for m in re.finditer(KIND + TP, s):
        kind, ko = m.group(1), re.sub(r"\\\([^)]*\)", "", m.group(2))
        limit = 60 if kind in ("footer: ", "detail: ") else 14
        if len(ko) > limit:
            bad.append("  %s:%d %s (%d > %d)" % (p, s[:m.start()].count("\n") + 1, m.group(2)[:40], len(ko), limit))
if bad:
    print("settings UI rule: keep row names short and put long explanations in more:", file=sys.stderr)
    print("\n".join(bad), file=sys.stderr)
    sys.exit(1)
PY
exit $fail
