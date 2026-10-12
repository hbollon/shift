# Contributing to Shift

Thanks for helping! This guide covers the development setup, the checks every change must pass, and the project
conventions. The [specification](docs/specs/0001-shift-v1.md) is the reference for behavior: read the relevant
section before changing a feature, and update the spec in the same pull request when behavior changes.

## Prerequisites

- Linux x86_64, `bash`, `make`, `git`, `curl`, `unzip`, Python ≥ 3.11.
- For live testing: [Noctalia](https://github.com/noctalia-dev/noctalia) ≥ 5.2.0, optionally `swayidle`.

## Setup

```sh
make tools   # installs the pinned toolchain into .tools/ (luau, luau-lsp, Noctalia type definitions, store validator)
make help    # lists every target
```

`make tools` also places `noctalia.d.luau` at the repository root (git-ignored) so editors with
[luau-lsp](https://github.com/JohnnyMorganz/luau-lsp) get autocomplete for the plugin API. Point luau-lsp at it in
your editor settings (kept local, `.vscode/` is git-ignored), e.g. for VS Code:

```json
{
  "luau-lsp.platform.type": "standard",
  "luau-lsp.sourcemap.enabled": false,
  "luau-lsp.types.definitionFiles": { "noctalia": "noctalia.d.luau" },
  "luau-lsp.ignoreGlobs": ["**/*.d.luau", "build/**", ".tools/**"]
}
```

## Running the plugin from your checkout

```sh
noctalia msg plugins source add shift-dev path ~/path/to/shift
noctalia msg plugins enable hbollon/shift
```

`.luau` edits hot-reload; manifest changes are picked up on the next config reload (`noctalia msg config-reload`).
Add the widget to a bar with `type = "hbollon/shift:bar"`, and drive entries over IPC:

```sh
noctalia msg panel-toggle hbollon/shift:dashboard
noctalia msg plugin hbollon/shift:core all <event> [payload]
```

Noctalia may send its log to `/dev/null` when started by the compositor; run it from a terminal
(`noctalia`) to see plugin logs.

## Checks

```sh
make check   # everything below, in order
make test    # Luau unit tests (FILTER=name to run matching spec files)
make analyze # luau-lsp type-check with the Noctalia definitions, host adapter check
make validate # community-plugins store validator on shift/
make catalog-check # catalog.toml mirrors shift/plugin.toml (regenerate with `make catalog`)
make lint    # `noctalia plugins lint` (local only, needs Noctalia)
```

CI runs `test`, `analyze`, `validate` and `catalog-check` on every push and pull request; all must pass before
merging.

## Project layout

```
shift/              the plugin, laid out exactly as in community-plugins
  plugin.toml       manifest (id hbollon/shift)
  core.luau         [[service]] — single source of truth
  bar.luau          [[widget]]  — bar widget
  dashboard.luau    [[panel]]   — dashboard panel
  tile.luau         [[shortcut]] — control-center tile
  lib/              shared modules (pure logic first)
  lib/signals/      signal sources (swayidle, logind) and their stream wrapper
  lib/ui/           shared UI components (the only modules using `ui`)
  translations/en.json
tests/              *.spec.luau unit tests, lib/testing.luau, lib/fake_host.luau, lib/json.luau
scripts/            toolchain, test runner, store validation, catalog generation
docs/specs/         specifications
docs/spikes/        platform validation reports
spikes/             throwaway spike plugin (not shipped)
```

## Code conventions

- Every `.luau` file starts with `--!nonstrict`, matching community-plugins.
- `require` uses relative paths **with** the extension: `require("./lib/time.luau")` (Noctalia requires it; the test
  runner strips it for the Luau CLI).
- Only `shift/lib/host.luau` touches the `noctalia` global; entries and modules use the adapter it returns
  (`make analyze` enforces it). The rendering globals of each entry type (`ui`, `barWidget`, `panel`, `shortcut`)
  are used directly, and only in the entry files; shared UI components in `shift/lib/ui/` may use `ui`.
- Keep logic in pure modules that receive the host as a parameter, so they are testable with
  `tests/lib/fake_host.luau`. Entry scripts stay thin.
- Shared domain types (persisted documents, snapshot, commands, host adapter) live in `shift/lib/types.luau`.
  Annotate the parameters and return types of every public module function and of values crossing entries; files
  stay `--!nonstrict`, so annotated code is checked by `make analyze` and the rest is inferred.
- Colors are palette roles only (`primary`, `on_surface_variant/0.6`, …) — never hex values in UI code.
- Every user-facing string goes through `noctalia.tr` / `noctalia.trp`. Add keys to `translations/en.json` only, as
  nested objects (no dotted keys); other languages come from [Noctalia Translate](https://i18n.noctalia.dev).
- Use the argument-array form of `noctalia.runAsync` whenever a value is dynamic.

## Tests

Spec files live in `tests/` and end with `.spec.luau`:

```lua
--!nonstrict
local t = require("./lib/testing.luau")
local FakeHost = require("./lib/fake_host.luau")

t.describe("module", function()
  t.it("does something", function()
    local host = FakeHost.new({ nowMs = 0, config = { weekly_hours = 35 } })
    t.expect(1 + 1).toBe(2)
  end)
end)

t.finish()
```

Matchers: `toBe`, `toEqual` (deep), `toBeNil`, `toBeTruthy`, `toBeFalsy`, `toThrow(pattern?)`.

The runner sets `TZ=Europe/Paris`, so calendar and DST tests are deterministic on any machine.

## Commits and pull requests

- [Conventional Commits](https://www.conventionalcommits.org), in English, subject line only — make it
  self-explanatory; add a body only when essential information cannot fit.
- Keep commits atomic: one logical change per commit.
- Bump `version` in `shift/plugin.toml` (semver) and run `make catalog` when releasing.
- Describe in the pull request any new network access, file write or spawned process — the store review requires it.
