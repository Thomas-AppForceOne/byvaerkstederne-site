---
title: Rediger begivenhed
template: event_edit
feature: event_management
slug: rediger
access:
    site.login: true
cache_enable: false
never_cache_twig: true

# Reached as /begivenheder/rediger/<key> — the event-manager plugin resolves
# the keyed route to this page and enforces ownership; every field's default
# is prefilled from the stored object per request via data-default@
# (FormDataProvider). The hidden `key` is a correlation value only: the POST
# handler re-resolves the object server-side and authorizes against the
# STORED owner. The card colour (button_style) is DERIVED from the group
# server-side; server-managed fields (owner, audit stamps, archived) never
# appear here.
form:
    name: event-edit
    action: /begivenheder/rediger
    fields:
        key:
            type: hidden
            data-default@: '\Grav\Plugin\EventManager\FormDataProvider::currentEventKey'

        section_about:
            type: display
            markdown: true
            content: "### Om begivenheden"

        title:
            type: text
            label: Titel
            help: "Overskriften på kortet i kalenderen. Hold den kort og sigende, fx 'Reparationscafé for cykler'."
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'title']
            validate:
                required: true

        group:
            type: select
            label: Værkstedsgruppe
            help: "Det værksted begivenheden hører til. Kortets farve følger automatisk værkstedet."
            validate:
                required: true
            data-options@: '\Grav\Plugin\EventManager\FormDataProvider::groupOptions'
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'group']

        description:
            type: textarea
            label: Beskrivelse
            help: "Et par linjer om hvad der sker, hvem det er for, og om man skal medbringe noget."
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'description']
            rows: 3

        badge:
            type: text
            label: Kategori-badge
            help: "Den lille farvede etiket øverst på kortet, fx værkstedets navn eller 'Kursus'. Kan stå tom."
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'badge']

        section_when:
            type: display
            markdown: true
            content: "### Tid & sted"

        event_date:
            type: text
            label: Dato
            help: "Skriv datoen som ÅÅÅÅ-MM-DD, fx 2026-08-22."
            placeholder: "ÅÅÅÅ-MM-DD"
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'event_date']
            validate:
                required: true

        event_time:
            type: text
            label: Tidspunkt
            help: "Fri tekst, fx '10:00 - 14:00' eller 'Hele dagen'. Kan stå tom."
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'event_time']

        location:
            type: text
            label: Lokation
            help: "Fx 'Makerspace lokalet' eller 'Hele området'. Kan stå tom."
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'location']

        section_signup:
            type: display
            markdown: true
            content: "### Tilmelding & pris\nAlt herunder er valgfrit — udfyld kun det, der er relevant."

        capacity:
            type: text
            label: Kapacitet
            help: "Fx '8 pladser' eller 'Begrænset plads'. Tom betyder ubegrænset."
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'capacity']

        price:
            type: text
            label: Pris
            help: "Fx '50 kr. voksne' eller 'Gratis entré'. Tom betyder at der ikke vises nogen pris."
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'price']

        button_text:
            type: text
            label: Knap-tekst
            help: "Teksten på kortets knap, fx 'Tilmeld'. Knappen vises kun, hvis der også er et link herunder."
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'button_text']

        button_url:
            type: text
            label: Knap-link
            help: "Hvor knappen fører hen: en side på sitet (fx /kontakt) eller en fuld adresse (https://…)."
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'button_url']

        section_visibility:
            type: display
            markdown: true
            content: "### Synlighed"

        published:
            type: toggle
            label: Synlig
            help: "Ja: begivenheden ligger i værkstedskalenderen. Nej: den trækkes tilbage som kladde, som kun du kan se under 'Mine begivenheder'."
            highlight: 1
            default: 1
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'published']
            options:
                1: Ja
                0: Nej

        featured:
            type: toggle
            label: Fremhævet
            help: "Fremhævede begivenheder vises med større overskrift i kalenderen. Brug det til de vigtigste arrangementer."
            highlight: 1
            default: 0
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'featured']
            options:
                1: Ja
                0: Nej

        featured_tag:
            type: text
            label: Fremhævet-tag
            help: "Lille tag på fremhævede begivenheder, fx 'All Hands'. Bruges kun når Fremhævet er slået til."
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'featured_tag']

    buttons:
        - type: submit
          value: Gem ændringer
          classes: bv-btn bv-btn--primary bv-btn--lg bv-btn--full
---
