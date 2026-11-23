# Dynamic MacNotch

macOS notch app (Swift, SwiftUI + AppKit, SwiftPM, no Xcode project). Start with `docs/ARCHITECTURE.md`: folder map, how to add a setting, page or Live Activity, settings screen rules and wording.

- Build: `scripts/build.sh [--dev] [--zip] [--install] [--run]`. `--dev` adds `-DDEV` (dev commands via `scripts/notchctl`).
- `@State` isn't available as a macro in this toolchain: write `private let x = State(initialValue: …)` and use `x.wrappedValue` / `x.projectedValue`.
- All user-facing text goes through `T("한국어", "English")`. Follow the wording table in `docs/ARCHITECTURE.md`.
- Settings: declare with `@Setting` in `Settings/AppSettings.swift`; never rename existing keys or rawValues.
- Settings screen (full rules in `docs/ARCHITECTURE.md` "설정 화면 규칙"; `scripts/check-settings-ui.sh` and `--settings-probe` enforce them on every build):
  - New page: `SettingsPage` case + `title` + `summary` + `symbol` (add it to the frozen symbol table in `SettingsProbe`; never change existing symbols), put it in one `SettingsGroup`, wrap the view in `SettingsForm { }`, add it to `SettingsView.content`.
  - Rows only through the components: `Toggle(_:detail:isOn:)`, `Choice` (enum, style picked by option count), `ListChoice`/`ChoiceMenu` (runtime lists), `ValueMenu` + a named list in `Choices` (keep old values), `ValueSlider`, `ListField`, `FolderSetting`; value text via `Format`. No raw `Picker`/`Slider`/`Stepper`/`.pickerStyle`/inline `values: [...]` in `Settings/Pages`.
  - Text: row name ≤ 14 Korean chars (short noun phrase), `detail:` and section `footer:` ≤ 60; longer text goes in `more:`; a disabled section gets `disabledNote:` (once per page). Follow the wording table.
  - Search: rows with a literal `T(...)` title are indexed automatically (`scripts/gen-settings-index.py` → `SettingsIndex+Generated.swift`, never edit by hand). Rows with runtime titles go in `SettingsIndex.manual`; settings with no row go in `SettingsIndex.internalKeys`. The probe fails if a setting can't be found.
  - After changing settings code: `scripts/build.sh --dev`, run the four probes, and check the running app is `/Applications` afterwards.
- Versioning: if no version is named for a release, raise the last digit by 1; after x.y.9 comes x.(y+1).0 (1.4.9 → 1.5.0). Also raise `CFBundleVersion` by 1.
- Before every release, run memory, CPU and leak tests on the release build and put the results in the release notes (both languages).
