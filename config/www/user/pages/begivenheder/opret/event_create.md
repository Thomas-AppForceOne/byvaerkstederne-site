---
title: Opret begivenhed
template: event_create
feature: event_management
slug: opret
access:
    site.login: true
cache_enable: false
never_cache_twig: true

# The create page is the inline card editor (event_create.html.twig): a custom
# <form> whose fields the organizer edits directly on the event card. It POSTs
# the same data[...] fields as before to /begivenheder/opret, where the
# event-manager plugin's §8.1 contract handler + EventValidator remain the
# unchanged server authority. There is deliberately NO Form-plugin `form:`
# block here — the CSRF nonce (nonce_field), the pre-generated key and the
# honeypot are rendered directly by the template, and the POST is intercepted
# by the plugin (pre-empting Form-plugin processing) exactly as before.
---
