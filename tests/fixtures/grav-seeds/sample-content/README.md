# Seed bundle: sample-content

Populates a running Grav container's `user/data/flex-objects/` with the
repo's sample dataset. This is the canonical source of local/dev sample
content now that flex data is no longer tracked in git (see
`specifications/flex_data_out_of_git_specification.md`).

## What it seeds

| File | Contents |
|---|---|
| `begivenheder.yaml` | 10 sample events across all four workshops (Makerspace, Krea Café, Grønt BYværksted, Eventværkstedet + one shared), five with rich `details_html`, two featured. Dates July–September 2026. |
| `roadmap-items.yaml` | Roadmap entries for the community roadmap page. |
| `teammedlemmer.yaml` | Team-member records (not yet used in production). |
| `opgaver.yaml` | Task records (not yet used in production). |
| `oenskeliste.yaml` | Wishlist records (not yet used in production). |

Deliberately **not** seeded: `bug-reports.yaml`, `feature-suggestions.yaml`,
`submission-tokens.yaml`, `events-audit.jsonl` — user-generated runtime
state; an empty store is the correct fresh state.

## Usage

```sh
# Against the main dev container (default name 'grav'):
tests/fixtures/grav-seeds/sample-content/apply.sh

# Against a named container (house naming is grav-<hash>):
tests/fixtures/grav-seeds/sample-content/apply.sh grav-44014582

# Via make (resolves the container for this checkout):
make seed-content
```

## Idempotence

Files already present in the container are **skipped**, so re-running never
overwrites runtime mutations (RSVP signups on events, roadmap votes,
organizer-created events). `--force` overwrites everything — only use it
when you explicitly want to reset local content to the sample state.

No secrets are involved; the bundle needs no `~/.gan-secrets` file.

## Keeping the dataset current

The sample event dates sit in July–September 2026. When they age out,
update `data/begivenheder.yaml` here (this bundle is the single place to
edit — there is no committed copy under `config/` any more).
