# Repository Guidelines

## Project Structure & Module Organization
`kagete` is a Swift Package Manager repository for a native macOS CLI. Main command and shared logic live in `Sources/kagete/`; overlay-specific code is grouped under `Sources/kagete/Overlay/`. Tests live in `Tests/kageteTests/`. Agent-facing documentation and reusable skill material live in `skills/kagete/` with `guides/` and `references/` subfolders. Release and install helpers are kept at the root in `install.sh` and `.github/workflows/`.

## Build, Test, and Development Commands
- `swift build` builds the debug binary.
- `swift build -c release` builds the optimized release binary used for packaging.
- `swift test` runs the unit test suite on macOS.
- `.build/debug/kagete doctor --json` runs the local binary without installing it.
- `./install.sh` installs the CLI into `~/.local/bin` for manual testing.

Use macOS 14+ on Apple Silicon. CI runs `swift build -v` and `swift test -v` on `macos-15`, so local changes should pass the same commands.

## Coding Style & Naming Conventions
Follow existing Swift style: 4-space indentation, one top-level type per concern, `UpperCamelCase` for types, `lowerCamelCase` for properties and functions, and verb-based command names such as `Find`, `Click`, and `Release`. Keep CLI output machine-friendly; JSON is the default interface, with readable text only where explicitly supported. There is no formatter or linter configured, so match surrounding code closely instead of introducing a new style.

## Testing Guidelines
Tests use Swift Testing (`import Testing`, `@Suite`, `@Test`). Add tests in `Tests/kageteTests/KageteTests.swift` or a nearby file named after the feature under test. Prefer focused assertions on behavior, such as key parsing, path generation, and JSON encoding. Run `swift test` before opening a PR.

## Commit & Pull Request Guidelines
Recent history follows Conventional Commit style: `feat:`, `feat(scope):`, `fix:`, and `docs(scope):`. Keep subjects short and imperative. PRs should explain the user-visible change, note how it was verified, and link any related issue. For overlay or screenshot changes, include a screenshot or terminal example. Do not bundle unrelated refactors with functional changes.

## Security & Permissions
`kagete` drives native apps through Accessibility and Screen Recording APIs. Never hardcode machine-specific paths or permission assumptions in code or docs. When changing capture or input behavior, verify with `kagete doctor --prompt` and document any new permission impact in `README.md`.
