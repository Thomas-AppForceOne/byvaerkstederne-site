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
ENV_FILE="$PROJECT_ROOT/.env.deploy"

REMOTE="hackersbychoice.dk@ssh.hackersbychoice.dk"
GRAV_ROOT="/customers/4/e/5/hackersbychoice.dk/httpd.www/test"
ACCOUNTS_DIR="$GRAV_ROOT/user/accounts"
GRAV_ENV="test.hackersbychoice.dk"
SUBJECT="Velkommen til Byværkstedernes website test"

source "$ENV_FILE"
mkdir -p "$(dirname "$LOG_FILE")"

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

    ACCOUNTS=$(remote "ls $ACCOUNTS_DIR/*.yaml 2>/dev/null | xargs -n1 basename" 2>/dev/null || echo "")

    if [ -z "$ACCOUNTS" ]; then
        log "No accounts found or SSH error"
        sleep 300
        continue
    fi

    for ACCOUNT_FILE in $ACCOUNTS; do
        USERNAME="${ACCOUNT_FILE%.yaml}"
        ACCOUNT_PATH="$ACCOUNTS_DIR/$ACCOUNT_FILE"

        ALREADY_INVITED=$(remote "grep -q '^test_invitation_sent_at:' '$ACCOUNT_PATH' && echo 1 || echo 0" 2>/dev/null || echo "0")
        if [ "$ALREADY_INVITED" = "1" ]; then
            ((ALREADY_SENT++))
            continue
        fi

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

        EMAIL_BODY="Hej $FULLNAME,

Velkommen til Byværkstedernes website test! Vi er glade for at have dig med.

Vi er ved at forbedre siden og vil gerne høre hvad du tænker. Herunder er nogle konkrete ting du kan prøve — det tager omkring 10-15 minutter:

1. Udforsk din konto
Gå til Min konto (øverst til højre) og prøv:
- Skift dit fulde navn
- Skift din adgangskode
- Skift din email (du får en bekræftelseslink)

Tip: Når du skifter email, får du en link sendt til den nye adresse. Det skal bekræftes.

2. Udforsk kalender og tilmeld workshops
Gå til Værkstedskalenderen og:
- Se hvilke workshops der er planlagt
- Filtrer efter kategori (f.eks. \"Makerspace\", \"Krea Café\")
- Klik ind på en workshop og se detaljer
- Tilmeld dig en workshop (RSVP)
- Gå tilbage til din konto og bekræft at du er tilmeldt

3. Anmod om at blive arrangør
Gå til Min konto → Rettigheder:
- Klik \"Anmod om at blive arrangør\"
- Skriv kort hvorfor du gerne vil være arrangør
- Din anmodning bliver behandlet af administratorerne

4. Prøv på din telefon
Besøg siden på din mobil og check at:
- Menuer virker
- Du kan læse siden uden at zoome
- Du kan udfylde formularer

---

Hvad giver mest mening?
Hvis noget virker uintuitivt, eller du er usikker på hvad du skal gøre — det er præcis den feedback vi søger.

Tak fordi du hjælper os!

Med venlig hilsen
Thomas"

        # Base64-encode body so newlines/quotes survive the ssh shell layers
        BODY_B64=$(printf '%s' "$EMAIL_BODY" | base64 | tr -d '\n')

        SEND_OUTPUT=$(remote "cd $GRAV_ROOT && BODY=\$(echo '$BODY_B64' | base64 -d) && php bin/plugin email test-email --env $GRAV_ENV -t '$EMAIL' -s '$SUBJECT' -b \"\$BODY\"" 2>&1 || echo "SSH_FAILED")

        if ! echo "$SEND_OUTPUT" | grep -q "Message sent successfully"; then
            log "  ❌ Email send failed for $USERNAME: $(echo "$SEND_OUTPUT" | tail -2 | tr '\n' ' ')"
            ((ERRORS++))
            continue
        fi

        log "  ✓ Email sent"

        # Append marker AFTER successful send (append, not sed - account YAML
        # has no guaranteed empty line for sed to match)
        if ! remote "echo 'test_invitation_sent_at: \"$TIMESTAMP\"' >> '$ACCOUNT_PATH'" 2>/dev/null; then
            log "  ⚠️  Email sent but failed to mark $USERNAME - WILL RESEND next cycle"
            ((SENT++))
            continue
        fi

        log "  ✓ Marked as invited"
        ((SENT++))
    done

    log "Summary: $SENT sent, $ALREADY_SENT already sent, $ERRORS errors"
    log "Next check in 5 minutes..."
    sleep 300
done
