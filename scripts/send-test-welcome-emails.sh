#!/bin/bash
#
# send-test-welcome-emails.sh
#
# Sends welcome emails to newly activated accounts on test.hackersbychoice.dk
# Runs in an infinite loop, checks every 5 minutes
# Usage: ./scripts/send-test-welcome-emails.sh
# Stop with: Ctrl+C
#

set -euo pipefail

PROJECT_ROOT="/Users/taa/AppForceOne/projects/workshop-site"
LOG_FILE="$PROJECT_ROOT/logs/test-welcome-agent.log"
ENV_FILE="$PROJECT_ROOT/.env.deploy"

# Load .env.deploy for server credentials
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ $ENV_FILE not found"
    exit 1
fi
source "$ENV_FILE"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Log function
log() {
    local msg="$1"
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $msg" | tee -a "$LOG_FILE"
}

# Get SSH password from keychain
get_ssh_password() {
    security find-generic-password -a "${USER:-}" -s "$DEPLOY_PASS_KEYCHAIN" -w 2>/dev/null || echo ""
}

# Trap for graceful shutdown
trap 'log "Shutting down..."; exit 0' SIGINT SIGTERM

log "Starting welcome email agent (loop every 5 minutes, press Ctrl+C to stop)"

# Main loop
while true; do
    # Get password (fresh each time in case keychain updates)
    SSH_PASS=$(get_ssh_password)
    if [ -z "$SSH_PASS" ]; then
        log "❌ ERROR: Could not read SSH password from keychain"
        sleep 300
        continue
    fi

    # Prompt for Claude to execute
    read -r -d '' PROMPT << 'EOF' || true
You are a helper that sends welcome emails to new test users.

**Task:** Send welcome emails to newly activated accounts on test.hackersbychoice.dk

**Important:** Work entirely with SSH commands — do NOT use any file-writing or editing tools for the account files. Use sed/awk via SSH only.

**Steps:**

1. SSH into test-tier and read accounts:
   - SSH connection: "hackersbychoice.dk@ssh.hackersbychoice.dk" on port 22
   - SSH command to list accounts: ssh -p 22 "hackersbychoice.dk@ssh.hackersbychoice.dk" "find /customers/4/e/5/hackersbychoice.dk/httpd.www/test/user/accounts -name '*.yaml' -type f -exec ls {} \;"
   - For each account file, extract email, fullname, and check if test_invitation_sent_at field exists

2. Identify new accounts (those WITHOUT test_invitation_sent_at field):
   - Must have email field set (account is activated)
   - Collect list

3. For each new account, send welcome email:
   - SSH to: ssh -p 22 "hackersbychoice.dk@ssh.hackersbychoice.dk"
   - Send email via Grav (figure out the command or use mail command)
   - Email recipient: the account's email address
   - Subject: "Velkommen til Byværkstedernes website test 🎉"
   - Email body (replace [name] with fullname or username):

Subject: Velkommen til Byværkstedernes website test 🎉

Hej [name],

Velkommen til Byværkstedernes website test! Vi er glade for at have dig med.

Vi er ved at forbedre siden og vil gerne høre hvad du tænker. Herunder er nogle konkrete ting du kan prøve — det tager omkring 10-15 minutter:

### 1. Udforsker din konto
Gå til Min konto (øverst til højre) og prøv:
- Skift dit fulde navn
- Skift din adgangskode
- Skift din email (du får en bekræftelseslink)

Tip: Når du skifter email, får du en link sendt til den nye adresse. Det skal bekræftes.

### 2. Udforsk kalender og tilmeld workshops
Gå til Værkstedskalenderen og:
- Se hvilke workshops der er planlagt
- Filtrer efter kategori (f.eks. "Makerspace", "Krea Café")
- Klik ind på en workshop og se detaljer
- Tilmeld dig en workshop (RSVP)
- Gå tilbage til din konto og bekræft at du er tilmeldt

### 3. Anmod om at blive arrangør
Gå til Min konto → Rettigheder:
- Klik "Anmod om at blive arrangør"
- Skriv kort hvorfor du gerne vil være arrangør
- Din anmodning bliver behandlet af administratorerne

### 4. Prøv på din telefon
Besøg siden på din mobil og check at:
- Menuer virker
- Du kan læse siden uden at zoome
- Du kan udfylde formularer

---

Hvad giver mest mening?
Hvis noget virker uintuitiv, eller du er usikker på hvad du skal gøre — det er præcis den feedback vi søker.

Tak fordi du hjælper os!

Med venlig hilsen
Thomas

4. After sending each email successfully, update the account YAML via SSH:
   - Use sed to add the test_invitation_sent_at field
   - Command: ssh -p 22 "hackersbychoice.dk@ssh.hackersbychoice.dk" "sed -i.bak 's/^$/test_invitation_sent_at: \"$(date -u +\"%Y-%m-%dT%H:%M:%SZ\")\"/' /path/to/account.yaml"

5. Output results for logging:
   - Each sent: "SENT: [fullname] ([email])"
   - Each error: "ERROR: [detail]"
   - Summary: "Summary: X sent, Y errors, Z no new accounts"

**Notes:**
- SSH password will be provided via environment
- If SSH fails, return error and exit gracefully
- This runs every 5 minutes — be efficient and quick
- Do NOT modify test_invitation_sent_at if email sending fails — let next run retry
- Focus on what actually works, not perfect solutions
EOF

    log "Checking for new accounts..."

    RESULT=$(export SSHPASS="$SSH_PASS" && claude "$PROMPT" 2>&1 || echo "Claude execution error")

    log "Result: $RESULT"
    log "---"

    # Wait 5 minutes before next check
    log "Sleeping 5 minutes until next check..."
    sleep 300
done
