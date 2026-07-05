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
# house styling). The POST is handled by the event-manager plugin's §8.1
# contract handler, which pre-empts Form-plugin processing — so there is no
# `process:` block. The `group`/`button_style` options below are placeholders:
# the plugin injects the real options from the begivenheder blueprint (single
# source of truth) at render time. Server-managed fields (owner, audit
# stamps, archived) never appear in the form.
form:
    name: event-create
    action: /begivenheder/opret
    fields:
        published:
            type: toggle
            label: Synlig
            help: "Synlige begivenheder vises med det samme i værkstedskalenderen. Vælg Nej for at gemme som kladde."
            highlight: 1
            default: 1
            options:
                1: Ja
                0: Nej

        title:
            type: text
            label: Titel
            validate:
                required: true

        description:
            type: textarea
            label: Beskrivelse
            rows: 3

        group:
            type: select
            label: Værkstedsgruppe
            validate:
                required: true
            data-options@: '\Grav\Plugin\EventManager\FormDataProvider::groupOptions'

        badge:
            type: text
            label: Kategori badge
            help: "Vises som farvet badge, f.eks. 'Makerspace & Reparation'"

        event_date:
            type: text
            label: Dato
            help: "Format: 2026-05-02"
            placeholder: "ÅÅÅÅ-MM-DD"
            validate:
                required: true

        event_time:
            type: text
            label: Tidspunkt
            help: "F.eks. '10:00 - 14:00'"

        location:
            type: text
            label: Lokation
            help: "F.eks. 'Hele området' eller 'Makerspace lokalet'"

        capacity:
            type: text
            label: Kapacitet
            help: "F.eks. '8 Pladser', 'Begrænset plads' eller tom for ubegrænset"

        price:
            type: text
            label: Pris
            help: "F.eks. '50 kr. voksne', 'Gratis entrè' eller tom"

        button_text:
            type: text
            label: Knap tekst
            default: Tilmeld

        button_url:
            type: text
            label: Tilmelding URL
            help: "En side på sitet (fx /vaerksteder) eller en fuld http(s)-adresse"

        button_style:
            type: select
            label: Knap stil
            default: primary
            data-options@: '\Grav\Plugin\EventManager\FormDataProvider::buttonStyleOptions'

        featured:
            type: toggle
            label: Fremhævet begivenhed
            help: Vises stort øverst på kalendersiden
            highlight: 1
            default: 0
            options:
                1: Ja
                0: Nej

        featured_tag:
            type: text
            label: Fremhævet tag
            help: "F.eks. 'All Hands' — kun vist når fremhævet"

        # Honeypot anti-spam field, hidden by CSS (.form-honeybear). Checked
        # server-side by the event-manager contract handler.
        website:
            type: honeypot

    buttons:
        - type: submit
          value: Opret begivenhed
          classes: bv-btn bv-btn--primary bv-btn--lg bv-btn--full
---
