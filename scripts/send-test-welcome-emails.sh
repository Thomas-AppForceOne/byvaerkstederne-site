#!/bin/bash
# send-test-welcome-emails.sh - Send welcome emails to new test accounts
# Run manually: ./scripts/send-test-welcome-emails.sh (loops every 5 min, Ctrl+C to stop)

set -euo pipefail

PROJECT_ROOT="/Users/taa/AppForceOne/projects/workshop-site"
LOG_FILE="$PROJECT_ROOT/logs/test-welcome-agent.log"
ENV_FILE="$PROJECT_ROOT/.env.deploy"

source "$ENV_FILE"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $1" | tee -a "$LOG_FILE"
}

trap 'log "Stopped"; exit 0' SIGINT SIGTERM

log "Starting welcome email agent (press Ctrl+C to stop)"

while true; do
    # Get SSH password from keychain
    SSH_PASS=$(security find-generic-password -a "${USER:-}" -s "$DEPLOY_PASS_KEYCHAIN" -w 2>/dev/null || echo "")

    if [ -z "$SSH_PASS" ]; then
        log "ERROR: Could not get SSH password from keychain"
        sleep 300
        continue
    fi

    log "Checking for new accounts..."

    # Count new accounts and send emails
    SENT=0
    ERRORS=0
    ALREADY_SENT=0

    # List account files on remote
    ACCOUNTS=$(SSHPASS="$SSH_PASS" sshpass -e ssh -o StrictHostKeyChecking=no -p 22 hackersbychoice.dk@ssh.hackersbychoice.dk \
        "ls /customers/4/e/5/hackersbychoice.dk/httpd.www/test/user/accounts/*.yaml 2>/dev/null | xargs -n1 basename" 2>/dev/null || echo "")

    if [ -z "$ACCOUNTS" ]; then
        log "No accounts found or SSH error"
        sleep 300
        continue
    fi

    for ACCOUNT_FILE in $ACCOUNTS; do
        USERNAME="${ACCOUNT_FILE%.yaml}"
        ACCOUNT_PATH="/customers/4/e/5/hackersbychoice.dk/httpd.www/test/user/accounts/$ACCOUNT_FILE"

        # Check if already sent
        ALREADY_INVITED=$(SSHPASS="$SSH_PASS" sshpass -e ssh -o StrictHostKeyChecking=no -p 22 hackersbychoice.dk@ssh.hackersbychoice.dk \
            "grep -q test_invitation_sent_at '$ACCOUNT_PATH' && echo 1 || echo 0" 2>/dev/null || echo "0")

        if [ "$ALREADY_INVITED" = "1" ]; then
            ((ALREADY_SENT++))
            continue
        fi

        # Get email and fullname from account
        EMAIL=$(SSHPASS="$SSH_PASS" sshpass -e ssh -o StrictHostKeyChecking=no -p 22 hackersbychoice.dk@ssh.hackersbychoice.dk \
            "grep '^email:' '$ACCOUNT_PATH' | sed 's/^email: //' | sed 's/\"//g'" 2>/dev/null || echo "")

        FULLNAME=$(SSHPASS="$SSH_PASS" sshpass -e ssh -o StrictHostKeyChecking=no -p 22 hackersbychoice.dk@ssh.hackersbychoice.dk \
            "grep '^fullname:' '$ACCOUNT_PATH' | sed 's/^fullname: //' | sed 's/\"//g'" 2>/dev/null || echo "$USERNAME")

        if [ -z "$EMAIL" ]; then
            log "  ⚠️  No email for $USERNAME, skipping"
            ((ERRORS++))
            continue
        fi

        # Send welcome email
        TIMESTAMP=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
        log "  📧 Sending email to $FULLNAME ($EMAIL)"

        # Update account with test_invitation_sent_at
        UPDATE_CMD="sed -i.bak 's/^$/test_invitation_sent_at: \"$TIMESTAMP\"/' '$ACCOUNT_PATH'"
        SSHPASS="$SSH_PASS" sshpass -e ssh -o StrictHostKeyChecking=no -p 22 hackersbychoice.dk@ssh.hackersbychoice.dk "$UPDATE_CMD" 2>/dev/null || {
            log "  ❌ Failed to update $USERNAME"
            ((ERRORS++))
            continue
        }

        log "  ✓ Marked as invited"
        ((SENT++))
    done

    log "Summary: $SENT sent, $ALREADY_SENT already sent, $ERRORS errors"
    log "Next check in 5 minutes..."
    sleep 300
done
