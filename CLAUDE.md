# Dynamic MacNotch

macOS notch app (Swift, SwiftUI + AppKit, SwiftPM, no Xcode project). Start with `docs/ARCHITECTURE.md`: folder map, how to add a setting, page or Live Activity, settings screen rules and wording.

- Build: `scripts/build.sh [--dev] [--zip] [--install] [--run]`. `--dev` adds `-DDEV` (dev commands via `scripts/notchctl`).
- `@State` isn't available as a macro in this toolchain: write `private let x = State(initialValue: …)` and use `x.wrappedValue` / `x.projectedValue`.
- All user-facing text goes through `T("한국어", "English")`. Follow the wording table in `docs/ARCHITECTURE.md`.
- Settings: declare with `@Setting` in `Settings/AppSettings.swift`; never rename existing keys or rawValues.
- Before every release, run memory, CPU and leak tests on the release build and put the results in the release notes (both languages).
