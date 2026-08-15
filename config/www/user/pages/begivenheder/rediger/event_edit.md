---
title: Rediger begivenhed
template: event_edit
slug: rediger
access:
    site.login: true
cache_enable: false
never_cache_twig: true

# Reached as /begivenheder/rediger/<key> — the event-manager plugin resolves
# the keyed route to this page and enforces ownership. The page is the inline
# card editor (event_edit.html.twig → partials/event_editor.html.twig), a
# custom <form> prefilled from the stored event (em_editor_state) that POSTs
# the same data[...] fields to /begivenheder/rediger. The hidden `key` is a
# correlation value only: the POST handler re-resolves the object server-side
# and authorizes against the STORED owner. There is deliberately NO Form-plugin
# `form:` block — the CSRF nonce (nonce_field) and honeypot are rendered
# directly and the POST is intercepted by the plugin, exactly as for create.
---
