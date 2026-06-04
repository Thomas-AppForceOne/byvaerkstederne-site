# Specification — Opening-day content mapping for the three live workshops

Status: Planned
Owner: thomas@appforceone.dk
Scope: Page renames, content rewrites, structural reorganisation under `/vaerksteder/`, and calendar repopulation, driven by the material delivered for the 6 June 2026 opening day.

---

## Goal

Replace every fictive content placeholder under `/vaerksteder/` with what the three actively-staffed workshops have supplied as physical material for the opening day, and reorganise Krea Café into a hub + sub-pages so the per-atelier content gets the room it needs.

The site has only ever been reachable on dev/test/staging; no external links to break. URL slugs are therefore free to change.

Material delivered (committed to the repo at `temp content/` before this work starts):

- `temp content/Grønt BYværksted/intro tekst.txt` — three short paragraphs
- `temp content/makerspace/MakerSpace hjemmeside.odt` — full prose + project examples + three calendar dates
- `temp content/Krea café/billedkunst/seksion A/Tekst til www.docx` + 4 WhatsApp images — six paper/print techniques, anonymous author
- `temp content/Krea café/billedkunst/seksion B/Billedkunst ved Lene Pels.docx` + 12 WhatsApp images — three techniques, two intro-session dates, signed Lene Pels
- `temp content/Krea café/Syværkstederne/PDF folder syværkstederne.pdf` — recurring sessions + four theme dates + two SMS contact numbers

---

## Non-goals

- Kulturhus — no material delivered; the page is left untouched.
- The fourth atelier planned under Krea Café — no material delivered, no card shown.
- Photos of the actual Hundested premises — none delivered, so the existing stock hero backgrounds stay as decorative.
- Leader contact cards — no real contact info delivered, so the Mads Nielsen placeholder cards are removed entirely. Contact falls back to a single "Kom forbi Nørregade 21, Hundested" line.
- URL redirects from the old slugs — the site has no external presence yet, no need to catch old paths.

---

## Slug + title changes

| Old path | New path | Old title | New title |
|---|---|---|---|
| `/vaerksteder/det-groenne-faellesskab` | `/vaerksteder/groent-byvaerksted` | Det Grønne Fællesskab | Grønt BYværksted |
| `/vaerksteder/kreativ-fitness` | `/vaerksteder/krea-cafe` | Kreativ Fitness | Krea Café |
| `/vaerksteder/makerspace` | (unchanged) | Makerspace & Reparation | (unchanged) |

Both folders move via `git mv`. Every hardcoded reference to the old slugs (workgroups cards on `/` and `/vaerksteder`, calendar filter values, any internal links) is grep-swept and updated in the same commit so the branch never has dangling links.

Calendar `filter:` values are rebranded for consistency: `groenne` → `groent`, `kreativ` → `krea`.

---

## Per-workshop structure

### Grønt BYværksted

Two-section modular page, unchanged shape:

1. `_01.hero` — new title, subtitle drawn from sentences 1-2 of `intro tekst.txt`. Existing stock hero image kept.
2. `_02.content` — three intro-text paragraphs as body. **Removed**: `progress_*` fields, `wishlist`, `donate_*`, `status_*`, `gallery_image`. The `groenne_content.html.twig` template is updated to drop the now-empty status/progress/wishlist/donate blocks rather than rendering empty cards. A single short "Kom forbi Nørregade 21, Hundested" line replaces the missing leader/donate call to action.

### Makerspace & Reparation

Four-section modular page becomes three (CTA card retired):

1. `_01.hero` — hero heading unchanged, subtitle rewritten from ODT.
2. `_02.projects` — section title changes to "Eksempler på projekter". Project list replaced with the four ODT examples (digitalt termometer, fugtighedsmåler, automatisk nattelampe, el-guitar). No project tag / link_text / team fields filled — those were fictive.
3. `_03.wishlist` — section hidden by deleting its modular folder; `makerspace_wishlist.html.twig` is left in place (still referenced by no page; safe to leave for later use). Modular `_04.cta` is also retired in the same way — leader contact placeholder removed wholesale, replaced by the same "Kom forbi Nørregade 21" line appended at the bottom of `_02.projects`'s template.

### Krea Café (Mulighed A — hub + sub-pages)

```
krea-cafe/                       (modular hub page)
  _01.hero                       new hero
  _02.ateliers                   three-card grid linking to sub-pages
  billedkunst/                   (modular sub-page)
    _01.hero
    _02.section_a                six technique cards (skraldebøger, gummistempler, blindtegning, gelli-print, paptryk, xerolitografi) + bento of 4 images from seksion A
    _03.section_b                three Lene Pels techniques (silketryk, photo transfer, maling/collage) + bento of selected images from seksion B + intro-session dates
  syvaerkstedet/                 (modular sub-page)
    _01.hero
    _02.intro                    upcycling pitch from PDF folder
    _03.sessions                 list of four upcoming sessions with SMS-link tilmelding
```

The hub's `_02.ateliers` uses the existing `gallery_bento.html.twig` template with custom labels (no new twig template required for the hub).

The two sub-pages reuse `hero.html.twig` for hero and `gallery_bento.html.twig` for image grids. The technique-card lists under billedkunst and the session list under syværkstedet use a new lightweight twig template (`atelier_techniques.html.twig`) — a simple list of `{title, description}` blocks, no progress bars or wishlists.

Images from `temp content/Krea café/billedkunst/seksion A/*.jpeg` (all 4) and a curated subset of `seksion B/*.jpeg` (4-6 of the 12) are copied into the corresponding page-media folders (Grav serves them automatically). The originals stay in `temp content/` until merge for traceability, then `temp content/` is deleted in a final cleanup commit (or kept in `.gitignore` — to be decided at PR review).

SMS contact numbers from the syværkstederne PDF render as `sms:+45<number>` links so they work as a tap-to-message on mobile.

---

## Calendar repopulation

`02.vaerkstedskalenderen/_04.events/event_list.md` is rewritten:

- **Removed**: all six existing entries (foredrag 30/4, laserskæring 2/5, stiklingsbytte 5/5, fællesspisning 7/5, keramik-klargøring 8/5, 3D-print openings night 15/5) — all fictive.
- **Added**: nine real entries —
  - Makerspace: ons 10/6, 17/6, 24/6 (all 18-20) "Elektronik og 3D-print for nybegyndere"
  - Krea Café / Billedkunst: ons 10/6 (15-17) photo transfer intro v. Lene Pels; lør 13/6 (11-13) silketryk intro v. Lene Pels
  - Krea Café / Syværksted: man 15/6 (18-20) sæsonstart; lør 27/6 (11-14) småbørnstøj v. Bitten; tir 30/6 (18-21.30) scrapbog v. Birgit; tor 9/7 (13-18) små punge/tasker v. Birgit

Badge labels follow the new titles ("Grønt BYværksted", "Krea Café", "Makerspace & Reparation"). Filter values match the rebranded `filter:` scheme.

---

## Removed fictive content (audit)

For the record, so reviewers can verify the "no placeholders survive" claim:

- `det-groenne-faellesskab` content: "Foråret banker på" paragraph, "Næste milepæl: Rejsning af glaskonstruktion (Uge 16)" progress note, wishlist (havesakse, såjord, lærketræ, regnvandstønde), "Donér Grej" CTA.
- `kreativ-fitness` content: PROJEKT A/B about Bernina restoration + lysborde, Keramik-værksted 20% progress, Industri-Overlocker / Keramikovn / Arbejdsborde wishlist.
- `makerspace` content: Sortering af værktøjsvæggen / Drejebænk-projekter, Søjleboremaskine / Stemmejern / 3D-filament wishlist, "Etablering af metal-hjørne" 60% milestone, Mads Nielsen leader card.
- All six existing calendar entries.

The kulturhus page is untouched and retains its current placeholder content — that's the next workshop's problem.

---

## Exit criteria

- `git grep` for `det-groenne-faellesskab` and `kreativ-fitness` returns nothing inside `config/` after the slug-rename commit.
- Each of the three workshop pages and the Krea Café hub + two sub-pages renders end-to-end on local Grav without empty cards, broken images, or references to removed contributors.
- Playwright suite passes (`make test`) with the seeded auth fixture.
- `/vaerkstedskalenderen` shows exactly the nine real events listed above and nothing else.
- No reference to "Mads Nielsen", "Bernina", "Drejebænk fra 1960erne", "Etablering af metal-hjørne", "Donér Grej", or "Næste milepæl: Rejsning af glaskonstruktion" remains anywhere under `config/`.
- The PR body documents the unresolved questions for follow-up (4th Krea Café atelier, leader contact info, real photos).
