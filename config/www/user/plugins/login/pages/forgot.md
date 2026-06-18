---
title: Glemt adgangskode
cache_control: private, no-cache, must-revalidate

login_redirect_here: false

metadata:
    description: 'Nulstil din adgangskode til Byværkstederne — indtast din e-mail, så sender vi dig et nulstillingslink.'

form:

    fields:
        - name: email
          type: email
          label: PLUGIN_LOGIN.EMAIL
          autofocus: true
          validate:
            required: true
            type: email
---


Indtast din e-mail for at nulstille din adgangskode.
