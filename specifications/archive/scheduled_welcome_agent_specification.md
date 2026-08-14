# Specification — Scheduled Welcome Agent for Test Users

Status: Implementation
Owner: thomas@appforceone.dk
Scope: Automatically send welcome & test-inspiration email to new activated user accounts on test.hackersbychoice.dk within 5 minutes of account activation.

---

## 1. Goal

When a new user creates and activates an account on test.hackersbychoice.dk, they should automatically receive a welcome email within ~5 minutes with concrete test scenarios and guidance on what to explore.

---

## 2. Execution

**Agent:** Scheduled Haiku model agent (Cloud-hosted)  
**Frequency:** Every 5 minutes  
**Tier:** test.hackersbychoice.dk only  
**Delivery method:** SSH → Grav's email plugin (bin/grav send:email)

---

## 3. Agent Logic

### Per run:
1. SSH into test-tier server
2. Read all account YAML files from `user/accounts/`
3. Identify accounts where:
   - `email` is set (activated)
   - `test_invitation_sent_at` is NOT set (no invitation yet)
4. For each new account:
   - Send welcome email (template below) via `bin/grav send:email`
   - Update account YAML to set `test_invitation_sent_at: <ISO timestamp>`
5. Log results to remote logfile: `/test/user/data/test-invitations.log`

### Email template:
```
Subject: Velkommen til Byværkstedernes website test 🎉

Hej [fullname or username],

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
```

---

## 4. Logging

**Log location:** `/test/user/data/test-invitations.log` (on remote server)

**Format:**
```
2026-07-18T10:00:00Z — SENT to: alice (alice@example.dk)
2026-07-18T10:00:05Z — SENT to: bob (bob@example.dk)
2026-07-18T10:05:00Z — No new accounts
2026-07-18T10:10:00Z — ERROR: SSH connection failed
```

**User can view live:** 
```bash
source .env.deploy && PASS=$(security find-generic-password -a "${USER:-}" -s "$DEPLOY_PASS_KEYCHAIN" -w 2>/dev/null) && sshpass -p "$PASS" ssh -p "$DEPLOY_PORT" "$DEPLOY_USER@$DEPLOY_HOST" "tail -f $DEPLOY_PATH/test/user/data/test-invitations.log"
```

---

## 5. Data Model

Account YAML gains a transient field:

```yaml
username: alice
email: alice@example.dk
fullname: "Alice Test"
password: "…"
groups: []
test_invitation_sent_at: "2026-07-18T10:00:00Z"  # ← NEW
```

---

## 6. Error Handling

If email send fails:
- Log the error
- Do NOT mark the account as sent
- Agent will retry on next run

If SSH fails:
- Log error with timestamp
- Agent exits gracefully
- Will retry in 5 minutes

---

## 7. Verification

After deployment:
- Watch logfile: `tail -f test/user/data/test-invitations.log`
- Create test account manually and verify email arrives within 5 minutes
- Check account YAML for `test_invitation_sent_at` field
