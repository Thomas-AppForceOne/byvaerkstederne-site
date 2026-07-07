---
title: Fjern begivenhed
template: event_delete
feature: event_management
slug: slet
access:
    site.login: true
cache_enable: false
never_cache_twig: true

# Reached as /begivenheder/slet/<key> — the event-manager plugin resolves the
# keyed route, enforces ownership, and injects the hidden key. For an
# arrangør the action is a reversible soft archive; a super can choose hard
# (permanent) delete — that choice is rendered by the template, and the
# handler enforces admin.super on mode=hard regardless of what is posted.
form:
    name: event-delete
    action: /begivenheder/slet
    fields:
        key:
            type: hidden
            data-default@: '\Grav\Plugin\EventManager\FormDataProvider::currentEventKey'

        mode:
            type: radio
            label: Sletningstype
            default: archive
            data-options@: '\Grav\Plugin\EventManager\FormDataProvider::deleteModeOptions'

    buttons:
        - type: submit
          value: Arkivér begivenheden
          classes: bv-btn bv-btn--tertiary bv-btn--lg bv-btn--full
---
