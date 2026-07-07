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
                            label: Titel
                            help: "Overskriften på kortet i kalenderen. Hold den kort og sigende, fx 'Reparationscafé for cykler'."
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'title']
                            validate:
                                required: true
                                pattern: "[^<>]{1,80}"

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

                        details:
                            type: textarea
                            label: Uddybende detaljer
                            help: "Længere beskrivelse med formatering og billeder. Vises når man åbner begivenheden. Alt indhold renses automatisk på serveren."
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'details']
                            rows: 8
                            classes: bv-rich-editor

                        section_when:
                            type: display
                            display_label: false
                            markdown: true
                            content: "### Tid & sted"

                        event_date:
                            type: date
                            label: Dato
                            help: "Vælg dagen for begivenheden."
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'event_date']
                            validate:
                                required: true

                        time_start:
                            type: time
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'time_start']
                            label: Starttidspunkt
                            help: "Hvornår begynder begivenheden?"
                            validate:
                                required: true

                        time_end:
                            type: time
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'time_end']
                            label: Sluttidspunkt
                            help: "Hvornår slutter den? Skal være efter starttidspunktet."
                            validate:
                                required: true

                        location:
                            type: text
                            label: Lokation
                            help: "Vælg Store Rum, Lille Rum eller Plænen — eller skriv selv et sted."
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'location']

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
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'capacity_unlimited']
                            label: Ubegrænset antal pladser
                            help: "Ubegrænsede begivenheder viser ikke et pladstal på kortet."
                            highlight: 1
                            default: 1
                            options:
                                1: Ja
                                0: Nej

                        capacity_count:
                            type: number
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'capacity_count']
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
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'price']

                        button_text:
                            type: select
                            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'button_text']
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
