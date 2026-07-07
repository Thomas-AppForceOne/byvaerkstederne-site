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
        # Pre-generated ev_<hex> key so images can be uploaded (§5.2) before the
        # event is first saved; handleCreate adopts it when still unused. It is
        # a correlation value only — never trusted for ownership.
        key:
            type: hidden
            data-default@: '\Grav\Plugin\EventManager\FormDataProvider::newEventKey'

        # Layout-only containers (form plugin columns/column fields): the two
        # form columns render under the full-width live preview. Nested field
        # names and POST data are unaffected by the nesting.
        layout_columns:
            type: columns
            fields:
                layout_column_left:
                    type: column
                    fields:

                        section_about:
                            type: display
                            display_label: false
                            markdown: true
                            content: "### Om begivenheden"

                        title:
                            type: text
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::oldInputDefault', 'title']
                            label: Titel
                            help: "Overskriften på kortet i kalenderen. Hold den kort og sigende, fx 'Reparationscafé for cykler'."
                            placeholder: "Fx 'Reparationscafé for cykler'"
                            validate:
                                required: true
                                pattern: "[^<>]{1,80}"

                        group:
                            type: select
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::oldInputDefault', 'group']
                            label: Værkstedsgruppe
                            help: "Det værksted begivenheden hører til. Kortets farve følger automatisk værkstedet."
                            validate:
                                required: true
                            data-options@: '\Grav\Plugin\EventManager\FormDataProvider::groupOptions'

                        description:
                            type: textarea
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::oldInputDefault', 'description']
                            label: Beskrivelse
                            help: "Et par linjer om hvad der sker, hvem det er for, og om man skal medbringe noget."
                            rows: 3

                        details:
                            type: textarea
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::oldInputDefault', 'details']
                            label: Uddybende detaljer
                            help: "Længere beskrivelse med formatering og billeder. Vises når man åbner begivenheden. Alt indhold renses automatisk på serveren."
                            rows: 8
                            classes: bv-rich-editor

                        section_when:
                            type: display
                            display_label: false
                            markdown: true
                            content: "### Tid & sted"

                        event_date:
                            type: date
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::oldInputDefault', 'event_date']
                            label: Dato
                            help: "Vælg dagen for begivenheden."
                            validate:
                                required: true

                        time_start:
                            type: time
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::oldInputDefault', 'time_start']
                            label: Starttidspunkt
                            help: "Hvornår begynder begivenheden?"
                            validate:
                                required: true

                        time_end:
                            type: time
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::oldInputDefault', 'time_end']
                            label: Sluttidspunkt
                            help: "Hvornår slutter den? Skal være efter starttidspunktet."
                            validate:
                                required: true

                        location:
                            type: text
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::oldInputDefault', 'location']
                            label: Lokation
                            help: "Vælg Store Rum, Lille Rum eller Plænen — eller skriv selv et sted."

                layout_column_right:
                    type: column
                    fields:

                        section_signup:
                            type: display
                            display_label: false
                            markdown: true
                            content: "### Tilmelding & pris\nAlt herunder er valgfrit — udfyld kun det, der er relevant."

                        capacity_unlimited:
                            type: toggle
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::oldInputDefault', 'capacity_unlimited']
                            label: Ubegrænset antal pladser
                            help: "Ubegrænsede begivenheder viser ikke et pladstal på kortet."
                            highlight: 1
                            default: 1
                            options:
                                1: Ja
                                0: Nej

                        capacity_count:
                            type: number
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::oldInputDefault', 'capacity_count']
                            label: Antal pladser
                            help: "Hvor mange kan deltage? Bruges kun når ubegrænset er slået fra."
                            validate:
                                min: 1
                                max: 9999

                        price:
                            type: select
                            label: Pris
                            help: "Gratis, Brugerbetaling eller Drop-in. 'Ingen prisvisning' skjuler prisen på kortet."
                            data-options@: '\Grav\Plugin\EventManager\FormDataProvider::priceOptions'
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::oldInputDefault', 'price']

                        button_text:
                            type: select
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::oldInputDefault', 'button_text']
                            label: Knap
                            help: "Knappen vises altid på kortet og åbner begivenheden. Vælg om den skal hedde Tilmeld eller Interesseret."
                            default: Tilmeld
                            data-options@: '\Grav\Plugin\EventManager\FormDataProvider::buttonTextOptions'

                        section_visibility:
                            type: display
                            display_label: false
                            markdown: true
                            content: "### Synlighed"

                        published:
                            type: toggle
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::oldInputDefault', 'published']
                            label: Synlig
                            help: "Ja: begivenheden ligger i værkstedskalenderen med det samme. Nej: den gemmes som kladde, som kun du kan se under 'Mine begivenheder'."
                            highlight: 1
                            default: 1
                            options:
                                1: Ja
                                0: Nej

                        featured:
                            type: toggle
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::oldInputDefault', 'featured']
                            label: Fremhævet
                            help: "Fremhævede begivenheder vises med større overskrift i kalenderen. Brug det til de vigtigste arrangementer."
                            highlight: 1
                            default: 0
                            options:
                                1: Ja
                                0: Nej

                        featured_tag:
                            type: text
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::oldInputDefault', 'featured_tag']
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
