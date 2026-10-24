# Contributing to Shift

Thanks for helping! This guide covers the development setup, the checks every change must pass, and the project conventions. The [specification](docs/specs/0001-shift-v1.md) is the reference for behavior: read the relevant section before changing a feature, and update the spec in the same pull request when behavior changes.

## Prerequisites

- Linux x86_64, `bash`, `make`, `git`, `curl`, `unzip`, Python ≥ 3.11.
- For live testing: [Noctalia](https://github.com/noctalia-dev/noctalia) ≥ 5.2.0, optionally `swayidle`.

## Setup

```sh
make tools   # installs the pinned toolchain into .tools/ (luau, luau-lsp, Noctalia type definitions, store validator)
make help    # lists every target
```

`make tools` also places `noctalia.d.luau` at the repository root (git-ignored) so editors with [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp) get autocomplete for the plugin API. Point luau-lsp at it in your editor settings (kept local, `.vscode/` is git-ignored), e.g. for VS Code:

```json
{
  "luau-lsp.platform.type": "standard",
  "luau-lsp.sourcemap.enabled": false,
  "luau-lsp.types.definitionFiles": { "noctalia": "noctalia.d.luau" },
  "luau-lsp.ignoreGlobs": ["**/*.d.luau", "build/**", ".tools/**"]
}
```

## Running the plugin from your checkout

With Noctalia v5 running:

```sh
make dev-install     # adds the checkout as a plugin source, enables Shift, adds the bar widget and control-center tile
make dev-uninstall   # undoes it; Shift's data is kept
```

The widget and tile are only added when no bar or shortcut has them yet, through a generated `~/.config/noctalia/zz-shift-dev.toml`. Doing it by hand:

```sh
noctalia msg plugins source add shift-dev path ~/path/to/shift
noctalia msg plugins enable hbollon/shift
```

then add the widget to a bar with `type = "hbollon/shift:bar"`.

`.luau` edits hot-reload; manifest changes are picked up on the next config reload (`noctalia msg config-reload`). Drive entries over IPC:

```sh
noctalia msg panel-toggle hbollon/shift:dashboard
noctalia msg plugin hbollon/shift:core all <event> [payload]
```

Noctalia may send its log to `/dev/null` when started by the compositor; run it from a terminal (`noctalia`) to see plugin logs.

## Checks

```sh
make check   # everything below, in order
make test    # Luau unit tests (FILTER=name to run matching spec files)
make analyze # luau-lsp type-check with the Noctalia definitions, host adapter check
make validate # community-plugins store validator on shift/
make catalog-check # catalog.toml mirrors shift/plugin.toml (regenerate with `make catalog`)
make lint    # `noctalia plugins lint` (local only, needs Noctalia)
```

CI runs `test`, `analyze`, `validate` and `catalog-check` on every push and pull request, and checks that pull request commits and titles follow the [commit conventions](#commits-and-pull-requests) (`scripts/check-commits.sh`); all must pass before merging.

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
scripts/            toolchain, test runner, store validation, catalog generation, release preparation
docs/user-guide.md  functional documentation for users
docs/assets/        logo, banner and README screenshots
docs/specs/         specifications
docs/spikes/        platform validation reports
spikes/             throwaway spike plugin (not shipped)
```

## Code conventions

- Every `.luau` file starts with `--!nonstrict`, matching community-plugins.
- `require` uses relative paths **with** the extension: `require("./lib/time.luau")` (Noctalia requires it; the test runner strips it for the Luau CLI).
- Only `shift/lib/host.luau` touches the `noctalia` global; entries and modules use the adapter it returns (`make analyze` enforces it). The rendering globals of each entry type (`ui`, `barWidget`, `panel`, `shortcut`) are used directly, and only in the entry files; shared UI components in `shift/lib/ui/` may use `ui`.
- Keep logic in pure modules that receive the host as a parameter, so they are testable with `tests/lib/fake_host.luau`. Entry scripts stay thin.
- Shared domain types (persisted documents, snapshot, commands, host adapter) live in `shift/lib/types.luau`. Annotate the parameters and return types of every public module function and of values crossing entries; files stay `--!nonstrict`, so annotated code is checked by `make analyze` and the rest is inferred.
- Colors are palette roles only (`primary`, `on_surface_variant/0.6`, …) — never hex values in UI code.
- Every user-facing string goes through `noctalia.tr` / `noctalia.trp`. Add keys to `translations/en.json` only, as nested objects (no dotted keys); other languages come from [Noctalia Translate](https://i18n.noctalia.dev).
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

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org) and are checked on every pull request (the commits and the pull request title):

```text
<type>[(scope)][!]: <subject>
```

| Type | For | In the changelog |
| --- | --- | --- |
| `feat` | A new feature, or a visible change to one | Features |
| `fix` | A bug fix | Bug fixes |
| `perf` | A performance improvement | Performance |
| `refactor` | Code changes that neither fix nor add anything | – |
| `docs` | Documentation only | – |
| `test` | Tests only | – |
| `build` | Toolchain, Makefile, scripts | – |
| `ci` | GitHub workflows | – |
| `chore` | Anything else (`chore(release)` is reserved for releases) | – |
| `style` | Formatting only | – |
| `revert` | Reverting an earlier commit | – |

- Write the subject in English, in the imperative mood and lowercase, without a final period: `feat: show the balance in the bar tooltip`. The `feat`, `fix` and `perf` subjects become the changelog, so write them for users.
- Use the subject line only, made self-explanatory. Add a body only when essential information cannot fit, such as the CVE fixed by a security commit.
- Mark a breaking change with `!` after the type (`feat!: …`), for example a change that needs users to act.
- A scope is optional; when used, it names the area: `fix(dashboard): …`.
- Keep commits atomic: one logical change per commit.
- Describe in the pull request any new network access, file write or spawned process — the store review requires it.

## Releases

Releases are made by the maintainer ([@hbollon](https://github.com/hbollon)) only: contributors do not bump the version or edit `CHANGELOG.md`. This section only documents the process.

Versions follow [semver](https://semver.org), and `CHANGELOG.md` is generated by [git-cliff](https://git-cliff.org) from the commit subjects (`feat`, `fix` and `perf` are listed), so they are written for users.

`make changelog` shows what the next release will list. Then release in one of two ways:

- **From GitHub** (the usual way): run the *Release* workflow from the Actions tab, or `gh workflow run release.yml -f version=auto`. With `auto`, the version comes from the commits since the last release (`feat` → minor, `fix` and `perf` → patch, `!` → major); or give one, such as `1.1.0`. The workflow sets the version in `shift/plugin.toml`, `catalog.toml` and `CHANGELOG.md`, runs the checks, commits `chore(release): X.Y.Z` as github-actions[bot] on `main`, tags it `vX.Y.Z` and publishes the GitHub release with the generated notes.
- **Locally**: prepare and tag the release yourself; pushing the tag publishes it, after checking that it matches `plugin.toml` and `CHANGELOG.md`.

  ```sh
  make prepare-release VERSION=1.1.0  # version in shift/plugin.toml, catalog.toml and CHANGELOG.md
  git add shift/plugin.toml catalog.toml CHANGELOG.md && git commit -m "chore(release): 1.1.0"
  git tag v1.1.0 && git push origin main v1.1.0
  ```

Then open the update PR on [community-plugins](https://github.com/noctalia-dev/community-plugins) (copy `shift/`, bumped version).
