#!/bin/bash
# send-test-welcome-emails.sh - Send welcome emails to new test accounts
#
# Sends the welcome/test-inspiration email to every activated account on
# test.hackersbychoice.dk that has not received one yet, via the email
# plugin's CLI (php bin/plugin email test-email --env test.hackersbychoice.dk)
# - the same SMTP transport that delivers activation emails.
#
# Run manually: ./scripts/send-test-welcome-emails.sh (loops every 5 min, Ctrl+C to stop)
# Logs to: logs/test-welcome-agent.log

set -euo pipefail

PROJECT_ROOT="/Users/taa/AppForceOne/projects/workshop-site"
LOG_FILE="$PROJECT_ROOT/logs/test-welcome-agent.log"
# Local record of usernames already invited. This is the primary duplicate
# gate: unlike the remote YAML-marker probe it needs no SSH connection, so
# a transient SSH failure can never be misread as "not yet invited".
SENT_LIST="$PROJECT_ROOT/logs/test-welcome-sent.txt"
ENV_FILE="$PROJECT_ROOT/.env.deploy"

REMOTE="hackersbychoice.dk@ssh.hackersbychoice.dk"
GRAV_ROOT="/customers/4/e/5/hackersbychoice.dk/httpd.www/test"
ACCOUNTS_DIR="$GRAV_ROOT/user/accounts"
GRAV_ENV="test.hackersbychoice.dk"
SUBJECT="Velkommen til Byværkstedernes website test"

source "$ENV_FILE"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$SENT_LIST"

log() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $1" | tee -a "$LOG_FILE"
}

remote() {
    SSHPASS="$SSH_PASS" sshpass -e ssh -o StrictHostKeyChecking=no -p 22 "$REMOTE" "$1"
}

trap 'log "Stopped"; exit 0' SIGINT SIGTERM

log "Starting welcome email agent (press Ctrl+C to stop)"

while true; do
    SSH_PASS=$(security find-generic-password -a "${USER:-}" -s "$DEPLOY_PASS_KEYCHAIN" -w 2>/dev/null || echo "")

    if [ -z "$SSH_PASS" ]; then
        log "ERROR: Could not get SSH password from keychain"
        sleep 300
        continue
    fi

    log "Checking for new accounts..."

    SENT=0
    ERRORS=0
    ALREADY_SENT=0
    PENDING=0

    ACCOUNTS=$(remote "ls $ACCOUNTS_DIR/*.yaml 2>/dev/null | xargs -n1 basename" 2>/dev/null || echo "")

    if [ -z "$ACCOUNTS" ]; then
        log "No accounts found or SSH error"
        sleep 300
        continue
    fi

    for ACCOUNT_FILE in $ACCOUNTS; do
        USERNAME="${ACCOUNT_FILE%.yaml}"
        ACCOUNT_PATH="$ACCOUNTS_DIR/$ACCOUNT_FILE"

        if grep -qx "$USERNAME" "$SENT_LIST"; then
            ((ALREADY_SENT++))
            continue
        fi

        # Remote marker probe, fail-CLOSED: "yes"/"no" is the remote grep's
        # answer; anything else means the SSH probe itself failed, and we
        # skip this cycle instead of resending. (Treating an SSH failure as
        # "not invited" is what caused participants to get duplicate mails.)
        ALREADY_INVITED=$(remote "grep -q '^test_invitation_sent_at:' '$ACCOUNT_PATH' && echo yes || echo no" 2>/dev/null || echo "error")
        case "$ALREADY_INVITED" in
            yes)
                echo "$USERNAME" >> "$SENT_LIST"
                ((ALREADY_SENT++))
                continue
                ;;
            no) ;;
            *)
                log "  ⚠️  Marker check failed for $USERNAME (SSH error) - skipping this cycle"
                ((ERRORS++))
                continue
                ;;
        esac

        # Only mail ACTIVATED accounts (spec: the welcome mail follows
        # activation). Registration creates accounts with state: disabled;
        # the account flips to enabled when the activation link is clicked,
        # and the next cycle picks it up. Fail-closed like the marker probe.
        STATE=$(remote "sed -n 's/^state:[[:space:]]*//p' '$ACCOUNT_PATH' | head -1" 2>/dev/null || echo "error")
        case "$STATE" in
            enabled) ;;
            disabled)
                ((PENDING++))
                continue
                ;;
            *)
                log "  ⚠️  State check failed for $USERNAME - skipping this cycle"
                ((ERRORS++))
                continue
                ;;
        esac

        EMAIL=$(remote "grep '^email:' '$ACCOUNT_PATH' | head -1 | sed 's/^email:[[:space:]]*//' | tr -d '\"'" 2>/dev/null || echo "")
        FULLNAME=$(remote "grep '^fullname:' '$ACCOUNT_PATH' | head -1 | sed 's/^fullname:[[:space:]]*//' | tr -d '\"'" 2>/dev/null || echo "")
        [ -z "$FULLNAME" ] && FULLNAME="$USERNAME"

        if [ -z "$EMAIL" ]; then
            log "  ⚠️  No email for $USERNAME, skipping"
            ((ERRORS++))
            continue
        fi

        TIMESTAMP=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
        log "  📧 Sending email to $FULLNAME ($EMAIL)"

        # The email plugin sends as text/html (site config), so the body is HTML.
        EMAIL_BODY="<p>Hej $FULLNAME,</p>
<p>Velkommen til Byværkstedernes website test! Vi er glade for at have dig med.</p>
<p>Vi er ved at forbedre siden og vil gerne høre hvad du tænker. Herunder er nogle konkrete ting du kan prøve — det tager omkring 10-15 minutter:</p>

<h3>1. Udforsk din konto</h3>
<p>Gå til <strong>Min konto</strong> (øverst til højre) og prøv:</p>
<ul>
<li>Skift dit fulde navn</li>
<li>Skift din adgangskode</li>
<li>Skift din email (du får en bekræftelseslink)</li>
</ul>
<p><em>Tip: Når du skifter email, får du en link sendt til den nye adresse. Det skal bekræftes.</em></p>

<h3>2. Udforsk kalender og tilmeld workshops</h3>
<p>Gå til <strong>Værkstedskalenderen</strong> og:</p>
<ul>
<li>Se hvilke workshops der er planlagt</li>
<li>Filtrer efter kategori (f.eks. &quot;Makerspace&quot;, &quot;Krea Café&quot;)</li>
<li>Klik ind på en workshop og se detaljer</li>
<li>Tilmeld dig en workshop (RSVP)</li>
<li>Gå tilbage til din konto og bekræft at du er tilmeldt</li>
</ul>

<h3>3. Anmod om at blive arrangør</h3>
<p>Gå til <strong>Min konto → Rettigheder</strong>:</p>
<ul>
<li>Klik &quot;Anmod om at blive arrangør&quot;</li>
<li>Skriv kort hvorfor du gerne vil være arrangør</li>
<li>Din anmodning bliver behandlet af administratorerne</li>
</ul>

<h3>4. Opret og redigér arrangementer (når du er arrangør)</h3>
<p>Når din arrangør-anmodning er godkendt, får du en ekstra knap i kalenderen:</p>
<ul>
<li>Gå til <strong>Værkstedskalenderen</strong> og klik <strong>&quot;Arrangørpanel&quot;</strong> (øverst)</li>
<li>Opret et nyt arrangement — udfyld titel, dato, tid, sted, beskrivelse og antal pladser</li>
<li>Find dit arrangement i kalenderen og se hvordan det ser ud for andre</li>
<li>Redigér arrangementet bagefter — ret f.eks. beskrivelsen eller antal pladser</li>
<li>Prøv også at slette et test-arrangement igen</li>
</ul>
<p><em>Det er en test-side, så du kan trygt oprette prøve-arrangementer.</em></p>

<h3>5. Prøv på din telefon</h3>
<p>Besøg siden på din mobil og check at:</p>
<ul>
<li>Menuer virker</li>
<li>Du kan læse siden uden at zoome</li>
<li>Du kan udfylde formularer</li>
</ul>

<hr/>
<p><strong>Feedback</strong><br/>
Hvis noget virker uintuitivt, eller du er usikker på hvad du skal gøre — det er præcis den feedback vi søger.<br/>
Send dine observationer til <a href=\"mailto:thomas@appforceone.dk\">thomas@appforceone.dk</a>.</p>
<p>Tak fordi du hjælper os!</p>
<p>Med venlig hilsen<br/>
Thomas</p>"

        # Base64-encode body so newlines/quotes survive the ssh shell layers
        BODY_B64=$(printf '%s' "$EMAIL_BODY" | base64 | tr -d '\n')

        SEND_OUTPUT=$(remote "cd $GRAV_ROOT && BODY=\$(echo '$BODY_B64' | base64 -d) && php bin/plugin email test-email --env $GRAV_ENV -t '$EMAIL' -s '$SUBJECT' -b \"\$BODY\"" 2>&1 || echo "SSH_FAILED")

        if ! echo "$SEND_OUTPUT" | grep -q "Message sent successfully"; then
            log "  ❌ Email send failed for $USERNAME: $(echo "$SEND_OUTPUT" | tail -2 | tr '\n' ' ')"
            ((ERRORS++))
            continue
        fi

        log "  ✓ Email sent"
        # Record locally FIRST - the participant has the mail now, and this
        # gate must hold even if the remote marker write below fails.
        echo "$USERNAME" >> "$SENT_LIST"

        # Append marker AFTER successful send (append, not sed - account YAML
        # has no guaranteed empty line for sed to match)
        if ! remote "echo 'test_invitation_sent_at: \"$TIMESTAMP\"' >> '$ACCOUNT_PATH'" 2>/dev/null; then
            log "  ⚠️  Email sent but failed to write remote marker for $USERNAME (local sent-list prevents resend)"
            ((SENT++))
            continue
        fi

        log "  ✓ Marked as invited"
        ((SENT++))
    done

    log "Summary: $SENT sent, $ALREADY_SENT already sent, $PENDING awaiting activation, $ERRORS errors"
    log "Next check in 5 minutes..."
    sleep 300
done
