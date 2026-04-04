---
title: Opret Medlemskab

form:
    name: registration
    action: /opret-medlemskab
    fields:
        - name: fullname
          type: text
          label: Navn (Medlem)
          placeholder: "F.eks. Anders Jensen"
          autocomplete: name
          validate:
            required: true

        - name: email
          type: email
          label: E-mail
          placeholder: "navn@domæne.dk"
          autocomplete: email
          validate:
            required: true

        - name: username
          type: text
          label: Brugernavn
          placeholder: "Vælg et brugernavn"
          autocomplete: username
          help: "3-16 tegn. Kun små bogstaver, tal, bindestreg og understregning."
          validate:
            required: true
            pattern: "^[a-z0-9_-]{3,16}$"
            message: "Brugernavn skal være 3-16 tegn og kun indeholde små bogstaver, tal, bindestreg og understregning."

        - name: password
          type: password
          label: Adgangskode
          placeholder: "Mindst 8 tegn"
          autocomplete: new-password
          help: "Mindst 8 tegn, med mindst ét tal, ét stort og ét lille bogstav."
          validate:
            required: true

    buttons:
        - type: submit
          value: Opret Medlemskab
          classes: bv-btn bv-btn--primary bv-btn--lg bv-btn--full

    process:
        - register_user:
            fields:
              - username
              - password
              - email
              - fullname
        - redirect: /
---

Ved at oprette medlemskab accepterer du vores [Vedtægter](/vedtaegter) og [Privatlivspolitik](/privatlivspolitik).
