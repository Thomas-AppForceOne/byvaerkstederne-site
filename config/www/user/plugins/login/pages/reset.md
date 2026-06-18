---
title: Nulstil adgangskode
cache_control: private, no-cache, must-revalidate

login_redirect_here: false

metadata:
    description: 'Vælg en ny adgangskode til din Byværkstederne-konto.'

form:

    fields:
        - name: username
          type: hidden
          id: username
          placeholder: PLUGIN_LOGIN.USERNAME_EMAIL
          readonly: true

        - name: password
          type: password
          id: password
          placeholder: PLUGIN_LOGIN.PASSWORD
          autofocus: true
          validate:
            required: true
            message: PLUGIN_LOGIN.PASSWORD_VALIDATION_MESSAGE
            config-pattern@: system.pwd_regex

        - name: token
          type: hidden

process:
    twig: true
---

Vælg en ny adgangskode for {{uri.param('user')}}.
