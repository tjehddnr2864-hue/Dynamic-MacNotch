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
exit $fail
