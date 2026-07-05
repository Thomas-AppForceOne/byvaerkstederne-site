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
# the keyed route to this page, enforces ownership, injects blueprint options
# and prefills every field's `default` from the stored object. The hidden
# `key` is a correlation value only: the POST handler re-resolves the object
# server-side and authorizes against the STORED owner. Server-managed fields
# (owner, audit stamps, archived) never appear here.
form:
    name: event-edit
    action: /begivenheder/rediger
    fields:
        key:
            type: hidden
            data-default@: '\Grav\Plugin\EventManager\FormDataProvider::currentEventKey'

        published:
            type: toggle
            label: Synlig
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'published']
            help: "Synlige begivenheder vises i værkstedskalenderen. Vælg Nej for at trække begivenheden tilbage som kladde."
            highlight: 1
            default: 1
            options:
                1: Ja
                0: Nej

        title:
            type: text
            label: Titel
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'title']
            validate:
                required: true

        description:
            type: textarea
            label: Beskrivelse
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'description']
            rows: 3

        group:
            type: select
            label: Værkstedsgruppe
            validate:
                required: true
            data-options@: '\Grav\Plugin\EventManager\FormDataProvider::groupOptions'
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'group']

        badge:
            type: text
            label: Kategori badge
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'badge']
            help: "Vises som farvet badge, f.eks. 'Makerspace & Reparation'"

        event_date:
            type: text
            label: Dato
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'event_date']
            help: "Format: 2026-05-02"
            placeholder: "ÅÅÅÅ-MM-DD"
            validate:
                required: true

        event_time:
            type: text
            label: Tidspunkt
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'event_time']
            help: "F.eks. '10:00 - 14:00'"

        location:
            type: text
            label: Lokation
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'location']
            help: "F.eks. 'Hele området' eller 'Makerspace lokalet'"

        capacity:
            type: text
            label: Kapacitet
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'capacity']
            help: "F.eks. '8 Pladser', 'Begrænset plads' eller tom for ubegrænset"

        price:
            type: text
            label: Pris
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'price']
            help: "F.eks. '50 kr. voksne', 'Gratis entrè' eller tom"

        button_text:
            type: text
            label: Knap tekst
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'button_text']

        button_url:
            type: text
            label: Tilmelding URL
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'button_url']
            help: "En side på sitet (fx /vaerksteder) eller en fuld http(s)-adresse"

        button_style:
            type: select
            label: Knap stil
            data-options@: '\Grav\Plugin\EventManager\FormDataProvider::buttonStyleOptions'
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'button_style']

        featured:
            type: toggle
            label: Fremhævet begivenhed
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'featured']
            help: Vises stort øverst på kalendersiden
            highlight: 1
            default: 0
            options:
                1: Ja
                0: Nej

        featured_tag:
            type: text
            label: Fremhævet tag
            data-default@: ['\Grav\Plugin\EventManager\FormDataProvider::eventFieldDefault', 'featured_tag']
            help: "F.eks. 'All Hands' — kun vist når fremhævet"

    buttons:
        - type: submit
          value: Gem ændringer
          classes: bv-btn bv-btn--primary bv-btn--lg bv-btn--full
---
