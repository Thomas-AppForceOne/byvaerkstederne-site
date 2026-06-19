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
            # Forbid angle brackets so the name cannot inject markup. The login
            # plugin interpolates fullname into the activation flash
            # (PLUGIN_LOGIN.ACTIVATION_NOTICE_MSG), which the site renders via
            # partials/messages.html.twig with |raw — without this gate a name
            # like "<img onerror=…>" would execute on the post-register redirect.
            # [^<>] still allows every real name (Unicode letters, spaces,
            # hyphens, apostrophes, periods); enforced server-side by the forms
            # plugin and client-side via the HTML5 pattern attribute.
            pattern: "^[^<>]{1,80}$"
            message: "Navnet må ikke indeholde tegnene < eller >."

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

        - name: password1
          type: password
          label: Adgangskode
          placeholder: "Mindst 8 tegn"
          autocomplete: new-password
          help: "Mindst 8 tegn, med mindst ét tal, ét stort og ét lille bogstav."
          validate:
            required: true
            # WI-5/WI-7: server-side password policy pinned in the page so the
            # forms plugin rejects a non-compliant password with a DANISH
            # message BEFORE Login::register() throws its English
            # RuntimeException (keeps the stock plugin unpatched). This pattern
            # is equivalent to system.pwd_regex (>=8 chars, >=1 upper, >=1
            # lower, >=1 digit) — pinned identical and proven equivalent to the
            # client-side JS chain by the shared truth-table fixture/test.
            pattern: "(?=.*[A-Z])(?=.*[0-9])(?=.*[a-z]).{8,}"
            message: "Adgangskoden skal være mindst 8 tegn og indeholde mindst ét tal, ét stort og ét lille bogstav."

        - name: password2
          type: password
          label: Gentag adgangskode
          placeholder: "Gentag din adgangskode"
          autocomplete: new-password
          help: "Skriv den samme adgangskode igen for at bekræfte."
          validate:
            required: true
            message: "Bekræft din adgangskode ved at skrive den igen."

        # Honeypot anti-spam field. Hidden from humans (CSS .form-honeybear in
        # register.html.twig), but bots fill every field. The forms plugin
        # rejects the submission server-side when a honeypot-type field is
        # non-empty (form.php onFormValidationProcessed). It is NOT in the
        # register_user process fields below, so it never reaches the account.
        - name: website
          type: honeypot

    buttons:
        - type: submit
          value: Opret Medlemskab
          classes: bv-btn bv-btn--primary bv-btn--lg bv-btn--full

    process:
        - register_user:
            fields:
              - username
              - password1
              - password2
              - email
              - fullname
        - redirect: /
---

Ved at oprette medlemskab accepterer du vores [Vedtægter](/vedtaegter) og [Privatlivspolitik](/privatlivspolitik).
