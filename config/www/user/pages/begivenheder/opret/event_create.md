---
title: Opret begivenhed
template: event_create
feature: event_management
slug: opret
access:
    site.login: true
cache_enable: false
never_cache_twig: true

# Rendered by the Form plugin (stock forms/form.html.twig → CSRF nonce +
# house styling) inside partials/event_form.html.twig, which adds the live
# event-card preview. The POST is handled by the event-manager plugin's §8.1
# contract handler, which pre-empts Form-plugin processing — so there is no
# `process:` block. The `group` options are injected from the begivenheder
# blueprint (single source of truth) per request via data-options@. The card
# colour (button_style) is DERIVED from the chosen group server-side — it is
# deliberately not a field. Server-managed fields (owner, audit stamps,
# archived) never appear in the form.
form:
    name: event-create
    action: /begivenheder/opret
    fields:
        section_about:
            type: display
            markdown: true
            content: "### Om begivenheden"

        title:
            type: text
            label: Titel
            help: "Overskriften på kortet i kalenderen. Hold den kort og sigende, fx 'Reparationscafé for cykler'."
            placeholder: "Fx 'Reparationscafé for cykler'"
            validate:
                required: true

        group:
            type: select
            label: Værkstedsgruppe
            help: "Det værksted begivenheden hører til. Kortets farve følger automatisk værkstedet."
            validate:
                required: true
            data-options@: '\Grav\Plugin\EventManager\FormDataProvider::groupOptions'

        description:
            type: textarea
            label: Beskrivelse
            help: "Et par linjer om hvad der sker, hvem det er for, og om man skal medbringe noget."
            rows: 3

        badge:
            type: text
            label: Kategori-badge
            help: "Den lille farvede etiket øverst på kortet, fx værkstedets navn eller 'Kursus'. Kan stå tom."

        section_when:
            type: display
            markdown: true
            content: "### Tid & sted"

        event_date:
            type: text
            label: Dato
            help: "Skriv datoen som ÅÅÅÅ-MM-DD, fx 2026-08-22."
            placeholder: "ÅÅÅÅ-MM-DD"
            validate:
                required: true

        event_time:
            type: text
            label: Tidspunkt
            help: "Fri tekst, fx '10:00 - 14:00' eller 'Hele dagen'. Kan stå tom."

        location:
            type: text
            label: Lokation
            help: "Fx 'Makerspace lokalet' eller 'Hele området'. Kan stå tom."

        section_signup:
            type: display
            markdown: true
            content: "### Tilmelding & pris\nAlt herunder er valgfrit — udfyld kun det, der er relevant."

        capacity:
            type: text
            label: Kapacitet
            help: "Fx '8 pladser' eller 'Begrænset plads'. Tom betyder ubegrænset."

        price:
            type: text
            label: Pris
            help: "Fx '50 kr. voksne' eller 'Gratis entré'. Tom betyder at der ikke vises nogen pris."

        button_text:
            type: text
            label: Knap-tekst
            help: "Teksten på kortets knap, fx 'Tilmeld'. Knappen vises kun, hvis der også er et link herunder."
            default: Tilmeld

        button_url:
            type: text
            label: Knap-link
            help: "Hvor knappen fører hen: en side på sitet (fx /kontakt) eller en fuld adresse (https://…)."

        section_visibility:
            type: display
            markdown: true
            content: "### Synlighed"

        published:
            type: toggle
            label: Synlig
            help: "Ja: begivenheden ligger i værkstedskalenderen med det samme. Nej: den gemmes som kladde, som kun du kan se under 'Mine begivenheder'."
            highlight: 1
            default: 1
            options:
                1: Ja
                0: Nej

        featured:
            type: toggle
            label: Fremhævet
            help: "Fremhævede begivenheder vises med større overskrift i kalenderen. Brug det til de vigtigste arrangementer."
            highlight: 1
            default: 0
            options:
                1: Ja
                0: Nej

        featured_tag:
            type: text
            label: Fremhævet-tag
            help: "Lille tag på fremhævede begivenheder, fx 'All Hands'. Bruges kun når Fremhævet er slået til."

        # Honeypot anti-spam field, hidden by CSS (.form-honeybear). Checked
        # server-side by the event-manager contract handler.
        website:
            type: honeypot

    buttons:
        - type: submit
          value: Opret begivenhed
          classes: bv-btn bv-btn--primary bv-btn--lg bv-btn--full
---
