// ============================================================================
// Bug Report Overlay
// ============================================================================
var bvBugReport = (function() {
    'use strict';

    var overlay = null;
    var panel = null;
    var triggerEl = null;
    var stepCount = 0;
    var prevFocus = null;

    // All focusable elements selector
    var FOCUSABLE = 'a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])';

    function init() {
        overlay = document.getElementById('bv-bug-report-overlay');
        if (!overlay) return; // Not rendered (unauthenticated)

        panel     = overlay.querySelector('.bv-bug-report-overlay__panel');
        triggerEl = document.getElementById('bv-bug-report-trigger');

        // Close buttons
        var closeBtn  = document.getElementById('bv-bug-report-close');
        var cancelBtn = document.getElementById('bv-bug-report-cancel-btn');
        if (closeBtn)  closeBtn.addEventListener('click', close);
        if (cancelBtn) cancelBtn.addEventListener('click', close);

        // Submit
        var submitBtn = document.getElementById('bv-bug-report-submit');
        if (submitBtn) submitBtn.addEventListener('click', submit);

        // Add step
        var addStepBtn = document.getElementById('bv-br-add-step');
        if (addStepBtn) addStepBtn.addEventListener('click', addStep);

        // File input
        var fileInput = document.getElementById('bv-br-image');
        var clearBtn  = document.getElementById('bv-br-image-clear');
        if (fileInput) {
            fileInput.addEventListener('change', function() {
                var errEl = document.getElementById('bv-br-image-error');
                if (errEl) errEl.textContent = '';
                if (!fileInput.files || !fileInput.files[0]) {
                    updateFileLabel('Vælg billede');
                    if (clearBtn) clearBtn.style.display = 'none';
                    return;
                }
                var file = fileInput.files[0];
                // Client-side MIME + extension check
                var allowedTypes = ['image/jpeg','image/png','image/gif','image/webp'];
                var allowedExts  = ['jpg','jpeg','png','gif','webp'];
                var ext = file.name.split('.').pop().toLowerCase();
                if (allowedTypes.indexOf(file.type) === -1 || allowedExts.indexOf(ext) === -1) {
                    if (errEl) errEl.textContent = 'Kun billedfiler er tilladt (JPEG, PNG, GIF, WebP).';
                    fileInput.value = '';
                    updateFileLabel('Vælg billede');
                    if (clearBtn) clearBtn.style.display = 'none';
                    return;
                }
                // Max 5 MB
                if (file.size > 5 * 1024 * 1024) {
                    if (errEl) errEl.textContent = 'Billedet er for stort. Maksimalt 5 MB tilladt.';
                    fileInput.value = '';
                    updateFileLabel('Vælg billede');
                    if (clearBtn) clearBtn.style.display = 'none';
                    return;
                }
                updateFileLabel(file.name);
                if (clearBtn) clearBtn.style.display = '';
            });
        }
        if (clearBtn) {
            clearBtn.addEventListener('click', function() {
                if (fileInput) fileInput.value = '';
                updateFileLabel('Vælg billede');
                clearBtn.style.display = 'none';
                var errEl = document.getElementById('bv-br-image-error');
                if (errEl) errEl.textContent = '';
            });
        }

        // Backdrop click closes overlay
        overlay.addEventListener('click', function(e) {
            if (e.target === overlay) close();
        });

        // Escape key + focus trap
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape' && overlay.classList.contains('is-open')) {
                close();
            }
            if (e.key === 'Tab' && overlay.classList.contains('is-open')) {
                trapFocus(e);
            }
        });
    }

    function updateFileLabel(text) {
        var lbl = document.getElementById('bv-br-image-label');
        if (lbl) lbl.textContent = text;
    }

    function generateToken() {
        if (typeof crypto !== 'undefined' && crypto.randomUUID) {
            return crypto.randomUUID();
        }
        // Fallback for older browsers
        return 'tok_' + Math.random().toString(36).slice(2) + Date.now().toString(36);
    }

    function populateContext() {
        // Page URL
        var urlInput   = document.getElementById('bv-bug-report-page-url');
        var urlDisplay = document.getElementById('bv-br-display-url');
        var currentUrl = window.location.href;
        if (urlInput)   urlInput.value = currentUrl;
        if (urlDisplay) urlDisplay.textContent = currentUrl;

        // Browser / OS from userAgent
        var uaInput   = document.getElementById('bv-bug-report-browser-os');
        var uaDisplay = document.getElementById('bv-br-display-browser');
        var ua = (navigator.userAgent && navigator.userAgent.trim() !== '') ? navigator.userAgent : 'Unknown';
        if (uaInput)   uaInput.value = ua;
        if (uaDisplay) uaDisplay.textContent = ua;

        // Fresh one-time submission token (prevents double-submit / retry creating duplicates)
        var tokenInput = document.getElementById('bv-bug-report-submission-token');
        if (tokenInput) tokenInput.value = generateToken();
    }

    function open() {
        if (!overlay) return;
        prevFocus = document.activeElement;
        populateContext();
        overlay.classList.add('is-open');
        overlay.setAttribute('aria-hidden', 'false');
        document.body.style.overflow = 'hidden';
        // Move focus to first focusable element inside panel
        setTimeout(function() {
            var focusable = panel.querySelectorAll(FOCUSABLE);
            if (focusable.length > 0) focusable[0].focus();
        }, 50);
    }

    function close() {
        if (!overlay) return;
        overlay.classList.remove('is-open');
        overlay.setAttribute('aria-hidden', 'true');
        document.body.style.overflow = '';
        if (prevFocus) {
            try { prevFocus.focus(); } catch(e) {}
        }
    }

    function resetForm() {
        var form = document.getElementById('bv-bug-report-form');
        if (form) form.reset();
        // Clear dynamic steps
        var stepsList = document.getElementById('bv-br-steps-list');
        if (stepsList) stepsList.innerHTML = '';
        stepCount = 0;
        // Clear field error messages
        document.querySelectorAll('.bv-bug-report-field-error').forEach(function(el) {
            el.textContent = '';
        });
        // Reset file label
        updateFileLabel('Vælg billede');
        var clearBtn = document.getElementById('bv-br-image-clear');
        if (clearBtn) clearBtn.style.display = 'none';
        // Hide any inline message
        showMessage('', '');
    }

    function addStep() {
        stepCount++;
        var stepsList = document.getElementById('bv-br-steps-list');
        if (!stepsList) return;

        var stepEl = document.createElement('div');
        stepEl.className = 'bv-bug-report-step';
        stepEl.setAttribute('data-step', stepCount);

        var numEl = document.createElement('span');
        numEl.className = 'bv-bug-report-step__num';
        numEl.textContent = (stepCount < 10 ? '0' : '') + stepCount;
        numEl.setAttribute('aria-hidden', 'true');

        var inputEl = document.createElement('input');
        inputEl.type = 'text';
        inputEl.className = 'bv-bug-report-step__input';
        inputEl.placeholder = 'Trin ' + stepCount + '...';
        inputEl.name = 'steps[]';
        inputEl.setAttribute('aria-label', 'Reproduktionstrin ' + stepCount);

        var removeBtn = document.createElement('button');
        removeBtn.type = 'button';
        removeBtn.className = 'bv-bug-report-step__remove';
        removeBtn.setAttribute('aria-label', 'Fjern trin ' + stepCount);
        removeBtn.innerHTML = '<span class="material-symbols-outlined" aria-hidden="true" style="font-size:1rem;">close</span>';
        removeBtn.addEventListener('click', function() {
            stepEl.remove();
            renumberSteps();
        });

        stepEl.appendChild(numEl);
        stepEl.appendChild(inputEl);
        stepEl.appendChild(removeBtn);
        stepsList.appendChild(stepEl);
        inputEl.focus();
    }

    function renumberSteps() {
        var steps = document.querySelectorAll('#bv-br-steps-list .bv-bug-report-step');
        steps.forEach(function(step, i) {
            var n = i + 1;
            var numEl    = step.querySelector('.bv-bug-report-step__num');
            var inputEl  = step.querySelector('.bv-bug-report-step__input');
            var removeEl = step.querySelector('.bv-bug-report-step__remove');
            if (numEl)    numEl.textContent = (n < 10 ? '0' : '') + n;
            if (inputEl)  { inputEl.placeholder = 'Trin ' + n + '...'; inputEl.setAttribute('aria-label', 'Reproduktionstrin ' + n); }
            if (removeEl) removeEl.setAttribute('aria-label', 'Fjern trin ' + n);
        });
        stepCount = steps.length;
    }

    function trapFocus(e) {
        var focusable = Array.prototype.slice.call(panel.querySelectorAll(FOCUSABLE));
        if (focusable.length === 0) { e.preventDefault(); return; }
        var first = focusable[0];
        var last  = focusable[focusable.length - 1];
        if (e.shiftKey) {
            if (document.activeElement === first) { e.preventDefault(); last.focus(); }
        } else {
            if (document.activeElement === last)  { e.preventDefault(); first.focus(); }
        }
    }

    function showMessage(text, type) {
        var msgEl = document.getElementById('bv-bug-report-message');
        if (!msgEl) return;
        if (!text) { msgEl.style.display = 'none'; msgEl.textContent = ''; return; }
        msgEl.className = 'bv-bug-report-message bv-bug-report-message--' + type;
        msgEl.textContent = text;
        msgEl.style.display = '';
        msgEl.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }

    function showFieldError(fieldId, message) {
        var el = document.getElementById(fieldId);
        if (el) el.textContent = message;
    }

    function clearFieldErrors() {
        document.querySelectorAll('.bv-bug-report-field-error').forEach(function(el) {
            el.textContent = '';
        });
    }

    function setSubmitting(isSubmitting) {
        var submitBtn = document.getElementById('bv-bug-report-submit');
        if (!submitBtn) return;
        submitBtn.disabled = isSubmitting;
        if (isSubmitting) {
            submitBtn.textContent = 'Sender...';
        } else {
            submitBtn.innerHTML = 'Send rapport <span class="material-symbols-outlined" aria-hidden="true" style="font-size:1.125rem;">send</span>';
        }
    }

    function submit() {
        clearFieldErrors();
        showMessage('', '');

        var descEl     = document.getElementById('bv-br-description');
        var expectedEl = document.getElementById('bv-br-expected');
        var isValid    = true;

        // Client-side required field validation
        if (!descEl || descEl.value.trim() === '') {
            showFieldError('bv-br-description-error', 'Dette felt er påkrævet.');
            if (descEl) descEl.focus();
            isValid = false;
        }
        if (!expectedEl || expectedEl.value.trim() === '') {
            showFieldError('bv-br-expected-error', 'Dette felt er påkrævet.');
            if (isValid && expectedEl) expectedEl.focus();
            isValid = false;
        }

        if (!isValid) return;

        // Build FormData from the form
        var form     = document.getElementById('bv-bug-report-form');
        var formData = new FormData(form);

        setSubmitting(true);

        fetch('/bug-report-submit', {
            method: 'POST',
            body: formData,
            headers: { 'X-Requested-With': 'XMLHttpRequest' },
            credentials: 'same-origin',
        })
        .then(function(response) {
            return response.json().then(function(data) {
                return { status: response.status, data: data };
            });
        })
        .then(function(result) {
            setSubmitting(false);
            if (result.status === 200 && result.data.success) {
                // Success: close overlay, reset form, show toast confirmation
                close();
                resetForm();
                var displayId   = result.data.display_id || '';
                var roadmapUrl  = result.data.roadmap_url || '/roadmap';
                var baseMessage = result.data.message || ('Tak! Din fejlrapport er nu live på roadmappet.');
                showConfirmation(baseMessage, roadmapUrl, displayId);
            } else {
                var errMsg = result.data.error || 'Indsendelsen mislykkedes. Prøv igen.';
                showMessage(errMsg, 'error');
                // Highlight specific field if indicated by server
                if (result.data.field === 'description') {
                    showFieldError('bv-br-description-error', errMsg);
                    if (descEl) descEl.focus();
                } else if (result.data.field === 'expected') {
                    showFieldError('bv-br-expected-error', errMsg);
                    if (expectedEl) expectedEl.focus();
                } else if (result.data.field === 'image') {
                    showFieldError('bv-br-image-error', errMsg);
                }
            }
        })
        .catch(function() {
            setSubmitting(false);
            showMessage('Netværksfejl. Kontrollér din forbindelse og prøv igen.', 'error');
        });
    }

    function showConfirmation(message, roadmapUrl, displayId) {
        var toast = document.createElement('div');
        toast.className = 'bv-bug-report-toast';
        toast.setAttribute('role', 'status');
        toast.setAttribute('aria-live', 'polite');
        // Build HTML: message text + roadmap links (general + anchor to specific item)
        var html = '<span>' + message.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;') + '</span>';
        // Link 1: General roadmap page
        html += ' <a href="/roadmap" style="color:inherit;text-decoration:underline;margin-left:0.25em;">Se roadmap</a>';
        // Link 2: Direct anchor link to the specific item (roadmapUrl is /roadmap#b004)
        if (roadmapUrl && roadmapUrl.indexOf('#') !== -1) {
            var safeAnchorUrl = roadmapUrl.replace(/&/g,'&amp;').replace(/"/g,'&quot;');
            var safeDisplayId = (displayId || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
            html += ' &mdash; <a href="' + safeAnchorUrl + '" style="color:inherit;text-decoration:underline;">G&aring; til ' + safeDisplayId + '</a>';
        }
        toast.innerHTML = html;
        toast.style.cssText = [
            'position:fixed',
            'bottom:5rem',
            'right:var(--space-8)',
            'z-index:300',
            'background:var(--primary)',
            'color:var(--on-primary)',
            'padding:var(--space-4) var(--space-8)',
            'font-family:var(--font-headline)',
            'font-weight:700',
            'font-size:0.875rem',
            'text-transform:uppercase',
            'letter-spacing:0.1em',
            'box-shadow:4px 4px 0 rgba(0,0,0,0.25)',
            'max-width:24rem',
            'border-left:4px solid var(--primary-fixed)',
        ].join(';');
        document.body.appendChild(toast);

        setTimeout(function() {
            toast.style.transition = 'opacity 0.4s';
            toast.style.opacity = '0';
            setTimeout(function() { toast.remove(); }, 400);
        }, 5000);
    }

    // Initialize when DOM is ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    return { open: open, close: close };
}());

// ============================================================================
// Feature Suggestion Overlay
// ============================================================================
var bvFeatureSuggestion = (function() {
    'use strict';

    var overlay = null;
    var panel = null;
    var prevFocus = null;

    // All focusable elements selector
    var FOCUSABLE = 'a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])';

    function init() {
        overlay = document.getElementById('bv-feature-suggestion-overlay');
        if (!overlay) return; // Not rendered (unauthenticated) — no-op

        panel = overlay.querySelector('.bv-feature-suggestion-overlay__panel');

        // Close buttons
        var closeBtn  = document.getElementById('bv-fs-overlay-close');
        var cancelBtn = document.getElementById('bv-fs-overlay-cancel-btn');
        if (closeBtn)  closeBtn.addEventListener('click', close);
        if (cancelBtn) cancelBtn.addEventListener('click', close);

        // Submit
        var submitBtn = document.getElementById('bv-fs-overlay-submit');
        if (submitBtn) submitBtn.addEventListener('click', submit);

        // Backdrop click closes overlay
        overlay.addEventListener('click', function(e) {
            if (e.target === overlay) close();
        });

        // Escape key + focus trap
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape' && overlay.classList.contains('is-open')) {
                close();
            }
            if (e.key === 'Tab' && overlay.classList.contains('is-open')) {
                trapFocus(e);
            }
        });
    }

    function generateToken() {
        if (typeof crypto !== 'undefined' && crypto.randomUUID) {
            return crypto.randomUUID();
        }
        return 'tok_' + Math.random().toString(36).slice(2) + Date.now().toString(36);
    }

    function refreshToken() {
        var tokenInput = document.getElementById('bv-fs-overlay-submission-token');
        if (tokenInput) tokenInput.value = generateToken();
    }

    function open() {
        if (!overlay) return;
        prevFocus = document.activeElement;
        // Reset form state on each open
        resetForm();
        // Generate a fresh submission token
        refreshToken();
        overlay.classList.add('is-open');
        overlay.setAttribute('aria-hidden', 'false');
        document.body.style.overflow = 'hidden';
        // Move focus to first focusable element inside panel
        setTimeout(function() {
            if (panel) {
                var focusable = panel.querySelectorAll(FOCUSABLE);
                if (focusable.length > 0) focusable[0].focus();
            }
        }, 50);
    }

    function close() {
        if (!overlay) return;
        overlay.classList.remove('is-open');
        overlay.setAttribute('aria-hidden', 'true');
        document.body.style.overflow = '';
        if (prevFocus) {
            try { prevFocus.focus(); } catch(e) {}
        }
    }

    function resetForm() {
        var form = document.getElementById('bv-fs-overlay-form');
        if (form) form.reset();
        // Clear field errors
        clearFieldErrors();
        // Hide message box
        showMessage('', '');
        // Hide confirmation, show form
        var confirmEl = document.getElementById('bv-fs-overlay-confirmation');
        if (confirmEl) { confirmEl.style.display = 'none'; confirmEl.innerHTML = ''; }
        if (form) form.style.display = '';
    }

    function trapFocus(e) {
        if (!panel) return;
        var focusable = Array.prototype.slice.call(panel.querySelectorAll(FOCUSABLE));
        if (focusable.length === 0) { e.preventDefault(); return; }
        var first = focusable[0];
        var last  = focusable[focusable.length - 1];
        if (e.shiftKey) {
            if (document.activeElement === first) { e.preventDefault(); last.focus(); }
        } else {
            if (document.activeElement === last)  { e.preventDefault(); first.focus(); }
        }
    }

    function showMessage(text, type) {
        var msgEl = document.getElementById('bv-fs-overlay-message');
        if (!msgEl) return;
        if (!text) { msgEl.style.display = 'none'; msgEl.textContent = ''; return; }
        msgEl.className = 'bv-fs-message bv-fs-message--' + type;
        msgEl.textContent = text;
        msgEl.style.display = '';
        msgEl.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }

    function showFieldError(errorId, msg) {
        var el = document.getElementById(errorId);
        if (el) el.textContent = msg;
    }

    function clearFieldErrors() {
        ['bv-fs-overlay-title-error', 'bv-fs-overlay-description-error', 'bv-fs-overlay-community-value-error'].forEach(function(id) {
            var el = document.getElementById(id);
            if (el) el.textContent = '';
        });
    }

    function setSubmitting(busy) {
        var submitBtn = document.getElementById('bv-fs-overlay-submit');
        if (!submitBtn) return;
        submitBtn.disabled = busy;
        if (busy) {
            submitBtn.textContent = 'Sender...';
        } else {
            submitBtn.innerHTML = 'Indsend forslag <span class="material-symbols-outlined" aria-hidden="true" style="font-size:1.125rem;">arrow_forward</span>';
        }
    }

    function showConfirmation(msg, roadmapUrl, displayId) {
        var form = document.getElementById('bv-fs-overlay-form');
        var confirmEl = document.getElementById('bv-fs-overlay-confirmation');
        if (!confirmEl) return;

        // Hide form, show confirmation panel
        if (form) form.style.display = 'none';
        showMessage('', '');

        var safemsg = msg.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');

        // General roadmap link
        var linkHtml = '<p class="bv-fs-confirmation__text">' +
            '<a href="/roadmap" class="bv-fs-sidebar__link">Se alle emner p\u00e5 roadmappet \u2192</a>' +
            '</p>';

        // Direct anchor link to the specific item
        if (roadmapUrl && roadmapUrl.indexOf('#') !== -1) {
            var safeAnchorUrl = roadmapUrl.replace(/&/g,'&amp;').replace(/"/g,'&quot;');
            var safeDisplayId = (displayId || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
            linkHtml += '<p class="bv-fs-confirmation__text">' +
                '<a href="' + safeAnchorUrl + '" class="bv-fs-sidebar__link">G\u00e5 direkte til dit forslag (' + safeDisplayId + ') \u2192</a>' +
                '</p>';
        }

        confirmEl.innerHTML =
            '<div class="bv-fs-confirmation__icon"><span class="material-symbols-outlined" aria-hidden="true">check_circle</span></div>' +
            '<h2 class="bv-fs-confirmation__title">Forslag publiceret!</h2>' +
            '<p class="bv-fs-confirmation__text">' + safemsg + '</p>' +
            linkHtml;

        confirmEl.style.display = '';
        confirmEl.focus();
    }

    function submit() {
        clearFieldErrors();
        showMessage('', '');

        var titleEl = document.getElementById('bv-fs-overlay-title-input');
        var descEl  = document.getElementById('bv-fs-overlay-description');
        var valueEl = document.getElementById('bv-fs-overlay-community-value');
        var isValid = true;

        // Client-side required field validation — first invalid field gets focus
        if (!titleEl || titleEl.value.trim() === '') {
            showFieldError('bv-fs-overlay-title-error', 'Dette felt er p\u00e5kr\u00e6vet.');
            if (titleEl && isValid) titleEl.focus();
            isValid = false;
        }
        if (!descEl || descEl.value.trim() === '') {
            showFieldError('bv-fs-overlay-description-error', 'Dette felt er p\u00e5kr\u00e6vet.');
            if (descEl && isValid) descEl.focus();
            isValid = false;
        }
        if (!valueEl || valueEl.value.trim() === '') {
            showFieldError('bv-fs-overlay-community-value-error', 'Dette felt er p\u00e5kr\u00e6vet.');
            if (valueEl && isValid) valueEl.focus();
            isValid = false;
        }

        if (!isValid) return;

        var form = document.getElementById('bv-fs-overlay-form');
        var formData = new FormData(form);

        setSubmitting(true);

        fetch('/feature-suggestion/submit', {
            method: 'POST',
            body: formData,
            headers: { 'X-Requested-With': 'XMLHttpRequest' },
            credentials: 'same-origin',
        })
        .then(function(response) {
            return response.json().then(function(data) {
                return { status: response.status, data: data };
            });
        })
        .then(function(result) {
            setSubmitting(false);
            if (result.status === 200 && result.data.success) {
                var displayId  = result.data.display_id || '';
                var roadmapUrl = result.data.roadmap_url || '/roadmap';
                var msg = result.data.message || 'Tak! Dit forslag er nu live p\u00e5 roadmappet.';
                showConfirmation(msg, roadmapUrl, displayId);
            } else {
                var errMsg = result.data.error || 'Indsendelsen mislykkedes. Pr\u00f8v igen.';
                showMessage(errMsg, 'error');
                // Map field-level errors from server response
                if (result.data.field === 'title') {
                    showFieldError('bv-fs-overlay-title-error', errMsg);
                    if (titleEl) titleEl.focus();
                } else if (result.data.field === 'description') {
                    showFieldError('bv-fs-overlay-description-error', errMsg);
                    if (descEl) descEl.focus();
                } else if (result.data.field === 'community_value') {
                    showFieldError('bv-fs-overlay-community-value-error', errMsg);
                    if (valueEl) valueEl.focus();
                }
            }
        })
        .catch(function() {
            setSubmitting(false);
            showMessage('Netv\u00e6rksfejl. Kontroll\u00e9r din forbindelse og pr\u00f8v igen.', 'error');
        });
    }

    // Initialize when DOM is ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    return { open: open, close: close };
}());

// ============================================================================
// Mobile menu toggle & existing UI
// ============================================================================
// Mobile menu toggle
document.addEventListener('DOMContentLoaded', function() {
    var hamburger = document.querySelector('.bv-nav__hamburger');
    if (hamburger) {
        hamburger.addEventListener('click', function() {
            document.body.classList.toggle('menu-open');
        });
    }

    // Close mobile menu on link click
    document.querySelectorAll('.bv-mobile-menu__link, .bv-mobile-menu__cta').forEach(function(link) {
        link.addEventListener('click', function() {
            document.body.classList.remove('menu-open');
        });
    });

    // Calendar filter buttons (exclusive: one active at a time, no deselect).
    // 'all' shows everything; 'mine' shows only the events the viewer is
    // tilmeldt/interesseret i (cards carrying .bv-event-row--attending); any
    // other value is a workshop group matched against the card's data-group.
    document.querySelectorAll('.bv-filter-btn[data-filter]').forEach(function(btn) {
        btn.addEventListener('click', function() {
            var group = this.dataset.filter;
            var rows = document.querySelectorAll('.bv-event-row[data-group]');

            // Clear all, activate only this one
            document.querySelectorAll('.bv-filter-btn[data-filter]').forEach(function(b) { b.classList.remove('is-active'); });
            this.classList.add('is-active');

            // Show matching rows
            var shown = 0;
            rows.forEach(function(row) {
                var show;
                if (group === 'all') {
                    show = true;
                } else if (group === 'mine') {
                    show = row.classList.contains('bv-event-row--attending');
                } else {
                    show = row.dataset.group === group;
                }
                row.style.display = show ? '' : 'none';
                if (show) { shown++; }
            });

            // "Mine aktiviteter" with nothing signed up → show the empty note.
            var emptyMine = document.querySelector('[data-empty-mine]');
            if (emptyMine) { emptyMine.hidden = !(group === 'mine' && shown === 0); }
        });
    });

    // To-Do overlay: close on Escape or clicking backdrop
    var todoOverlay = document.getElementById('bv-todo-overlay');
    if (todoOverlay) {
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape' && todoOverlay.classList.contains('is-open')) {
                todoOverlay.classList.remove('is-open');
                document.body.style.overflow = '';
            }
        });
        todoOverlay.addEventListener('click', function(e) {
            if (e.target === todoOverlay) {
                todoOverlay.classList.remove('is-open');
                document.body.style.overflow = '';
            }
        });
    }

    // Login overlay: close on Escape or clicking backdrop
    var loginOverlay = document.getElementById('bv-login-overlay');
    if (loginOverlay) {
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape' && loginOverlay.classList.contains('is-open')) {
                loginOverlay.classList.remove('is-open');
                document.body.style.overflow = '';
            }
        });
        loginOverlay.addEventListener('click', function(e) {
            if (e.target === loginOverlay) {
                loginOverlay.classList.remove('is-open');
                document.body.style.overflow = '';
            }
        });
    }

    // Year filter for archive
    document.querySelectorAll('.bv-year-btn').forEach(function(btn) {
        btn.addEventListener('click', function() {
            document.querySelectorAll('.bv-year-btn').forEach(function(b) { b.classList.remove('is-active'); });
            this.classList.add('is-active');
            var year = this.dataset.year;
            document.querySelectorAll('.bv-archive-section').forEach(function(section) {
                if (year === 'all' || section.dataset.year === year) {
                    section.style.display = '';
                } else {
                    section.style.display = 'none';
                }
            });
        });
    });
});

// ============================================================================
// Auth modals (forgot/register): close on Escape / backdrop click like the
// login overlay; and auto-dismiss flash messages after 5s.
// ============================================================================
document.addEventListener('DOMContentLoaded', function () {
    // Close the forgot/register modals on backdrop click (login is handled above).
    ['bv-forgot-overlay', 'bv-register-overlay'].forEach(function (id) {
        var ov = document.getElementById(id);
        if (ov) {
            ov.addEventListener('click', function (e) {
                if (e.target === ov && typeof bvOpenOverlay === 'function') { bvOpenOverlay(null); }
            });
        }
    });
    document.addEventListener('keydown', function (e) {
        if (e.key !== 'Escape') { return; }
        if (document.querySelector('#bv-forgot-overlay.is-open, #bv-register-overlay.is-open')
            && typeof bvOpenOverlay === 'function') { bvOpenOverlay(null); }
    });

    // Auto-dismiss flash messages (e.g. "You have been successfully logged in.")
    // Hold 5s, fade out, then remove so the layout reflows.
    var HOLD_MS = 5000;
    var FADE_MS = 600;
    document.querySelectorAll('.bv-messages .bv-message, .bv-register-card .form-messages .alert').forEach(function (m) {
        setTimeout(function () {
            m.style.transition = 'opacity ' + FADE_MS + 'ms ease';
            m.style.opacity = '0';
            setTimeout(function () { if (m && m.parentNode) { m.parentNode.removeChild(m); } }, FADE_MS + 50);
        }, HOLD_MS);
    });
});

// ============================================================================
// Event RSVP — the card button IS the live signup action (event_rsvp).
// Delegated so it works for cards injected on any surface (calendar, detail,
// and the Phase-4 modal, which can show the same event twice). Anonymous →
// login overlay; authenticated → AJAX toggle with optimistic UI, nonce
// rotation, and rollback on error. Follows the roadmap-vote button pattern.
// ============================================================================
(function () {
    'use strict';

    var ENDPOINT = '/begivenheder/tilmeld';

    function nonceInput() { return document.querySelector('#bv-em-rsvp-nonce [name="rsvp_nonce"]'); }
    function isAuthenticated() { return !!nonceInput(); }
    function getNonce() { var el = nonceInput(); return el ? el.value : ''; }
    function setNonce(value) { var el = nonceInput(); if (el && value) { el.value = value; } }

    function cssEscape(s) {
        if (window.CSS && CSS.escape) { return CSS.escape(s); }
        return String(s).replace(/["\\\]]/g, '\\$&');
    }

    // Danish label/state for a button given mode + signed-up + availability —
    // must mirror the Twig-rendered initial state in partials/event_card.html.twig.
    // The label is a fixed word per mode; the joined/marked state is shown by
    // the checkbox before it (CSS ::before on .is-signed-up), not the text.
    function labelFor(mode) {
        if (mode === 'interesseret') { return 'Interesseret'; }
        // A full event keeps the 'Deltag' label but is disabled (see the button
        // markup); the availability line carries "Alle pladser er optaget".
        return 'Deltag';
    }
    function stateFor(mode, signedUp, isFull) {
        if (mode === 'interesseret') { return signedUp ? 'marked' : 'open'; }
        if (signedUp) { return 'signed_up'; }
        if (isFull) { return 'full'; }
        return 'open';
    }
    function availabilityText(mode, count, remaining) {
        if (remaining !== null && remaining !== undefined) {
            if (remaining > 0) { return remaining + ' plads' + (remaining === 1 ? '' : 'er') + ' tilbage'; }
            return 'Alle pladser er optaget';
        }
        if (mode === 'interesseret') { return count + ' ' + (count === 1 ? 'interesseret' : 'interesserede'); }
        return count + ' tilmeldt' + (count === 1 ? '' : 'e');
    }

    // Update every card + availability line sharing this key from a server result.
    function applyResult(key, signedUp, count, remaining) {
        var sel = '[data-rsvp-key="' + cssEscape(key) + '"]';
        var mode = 'tilmeld';
        var firstBtn = document.querySelector(sel);
        if (firstBtn) { mode = firstBtn.getAttribute('data-rsvp-mode') || 'tilmeld'; }
        var isFull = (remaining !== null && remaining !== undefined && remaining <= 0) && !signedUp;

        document.querySelectorAll(sel).forEach(function (btn) {
            var m = btn.getAttribute('data-rsvp-mode') || 'tilmeld';
            btn.textContent = labelFor(m);
            btn.setAttribute('data-rsvp-state', stateFor(m, signedUp, isFull));
            btn.classList.toggle('is-signed-up', signedUp);
            btn.disabled = isFull;
        });
        document.querySelectorAll('[data-rsvp-availability="' + cssEscape(key) + '"]').forEach(function (line) {
            line.textContent = availabilityText(mode, count, remaining);
        });
        // Highlight the card (light workshop-colour date block) while the user
        // has joined — SAME treatment whether they are tilmeldt or interesseret.
        // Resolve the card off the signup button rather than [data-event-key]:
        // an event without rich details is not expandable and carries no
        // data-event-key, but can still be joined and must still get the highlight.
        document.querySelectorAll('[data-rsvp-key="' + cssEscape(key) + '"]').forEach(function (b) {
            var card = b.closest('.bv-event-row');
            if (card) { card.classList.toggle('bv-event-row--attending', signedUp); }
        });
    }

    // Inline feedback near the button (never a dialog — dialogs block automation).
    function announce(btn, msg) {
        var row = btn.closest('.bv-event-row') || btn.parentElement;
        if (!row) { return; }
        var note = row.querySelector('.bv-event-row__rsvp-note');
        if (!note) {
            note = document.createElement('span');
            note.className = 'bv-event-row__rsvp-note';
            note.setAttribute('role', 'status');
            btn.insertAdjacentElement('afterend', note);
        }
        note.textContent = msg;
    }

    function toggle(btn) {
        var key = btn.getAttribute('data-rsvp-key');
        if (!key || btn.disabled || btn.dataset.busy === '1') { return; }

        var prev = {
            label: btn.textContent,
            state: btn.getAttribute('data-rsvp-state'),
            signed: btn.classList.contains('is-signed-up')
        };
        btn.dataset.busy = '1';
        btn.classList.add('is-busy');

        var body = new FormData();
        body.append('data[key]', key);
        body.append('rsvp_nonce', getNonce());

        fetch(ENDPOINT, {
            method: 'POST',
            body: body,
            headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
            credentials: 'same-origin'
        })
        .then(function (r) { return r.json().then(function (d) { return { status: r.status, data: d }; }); })
        .then(function (res) {
            btn.dataset.busy = '';
            btn.classList.remove('is-busy');
            if (res.status === 200 && res.data && res.data.success) {
                if (res.data.new_nonce) { setNonce(res.data.new_nonce); }
                var signedUp = res.data.action === 'signed_up';
                var remaining = (res.data.remaining === undefined) ? null : res.data.remaining;
                applyResult(key, signedUp, res.data.count, remaining);
            } else {
                // Roll back the optimistic UI first.
                btn.textContent = prev.label;
                btn.setAttribute('data-rsvp-state', prev.state);
                btn.classList.toggle('is-signed-up', prev.signed);
                if (res.status === 401) {
                    // The session expired mid-action (typically after a redeploy):
                    // the stale page still carries the user's nonce input so the
                    // client thought it was logged in. Send the user to log in
                    // rather than showing a dead "not authorized" message.
                    if (typeof bvOpenOverlay === 'function') { bvOpenOverlay('bv-login-overlay'); }
                    else { window.location.href = '/login'; }
                } else {
                    // Surface the server message (409 full/past, 403 stale nonce).
                    var msg = (res.data && res.data.data && res.data.data.error)
                        || (res.data && res.data.error)
                        || 'Handlingen mislykkedes. Prøv igen.';
                    announce(btn, msg);
                }
            }
        })
        .catch(function () {
            btn.dataset.busy = '';
            btn.classList.remove('is-busy');
            btn.textContent = prev.label;
            btn.setAttribute('data-rsvp-state', prev.state);
            btn.classList.toggle('is-signed-up', prev.signed);
            announce(btn, 'Netværksfejl. Kontrollér din forbindelse og prøv igen.');
        });
    }

    document.addEventListener('click', function (e) {
        var btn = e.target.closest('[data-rsvp-key]');
        if (!btn) { return; }
        e.preventDefault();
        e.stopPropagation(); // never bubble to the card-expand handler (Phase 4)
        if (!isAuthenticated()) {
            if (typeof bvOpenOverlay === 'function') { bvOpenOverlay('bv-login-overlay'); }
            return;
        }
        toggle(btn);
    });
}());

// ============================================================================
// Event card inline expansion (event_rsvp §4). Clicking a card anywhere that
// is NOT the signup button expands it in place: the rich details unfold in a
// panel below the card and push the other events down (accordion — one open at
// a time). No modal, no URL change. The title's <a href> still opens the full
// detail page on cmd/ctrl/middle-click and for no-JS / SEO / crawlers.
// ============================================================================
(function () {
    'use strict';

    function itemOf(card) { return card.closest('.bv-event-item'); }
    function panelOf(card) { var it = itemOf(card); return it ? it.querySelector('.bv-event-details-panel') : null; }
    function templateOf(card) { var it = itemOf(card); return it ? it.querySelector('[data-event-details]') : null; }

    function collapse(card) {
        var panel = panelOf(card);
        if (panel) { panel.hidden = true; panel.innerHTML = ''; }
        card.classList.remove('is-expanded');
        card.setAttribute('aria-expanded', 'false');
    }

    function expand(card) {
        // Accordion: only one card open at a time.
        document.querySelectorAll('.bv-event-row.is-expanded').forEach(function (c) {
            if (c !== card) { collapse(c); }
        });
        var panel = panelOf(card);
        if (!panel) { return; }
        var tpl = templateOf(card);
        // Only cards that carry rich details are expandable (the chevron and
        // click target render solely for them), so the template is always
        // non-empty here — no placeholder branch.
        panel.innerHTML = tpl ? tpl.innerHTML : '';
        panel.querySelectorAll('img').forEach(function (img) { img.loading = 'lazy'; });
        panel.hidden = false;
        card.classList.add('is-expanded');
        card.setAttribute('aria-expanded', 'true');
    }

    function toggle(card) {
        if (card.classList.contains('is-expanded')) { collapse(card); }
        else { expand(card); }
    }

    // A click ANYWHERE on the card except the signup button toggles the inline
    // details. The title is plain text (no link). Any real link inside the card
    // — e.g. a mailto: the description text was linkified into — still works;
    // everything else expands the card. Clicks inside the expanded panel are
    // NOT on the card (it's a sibling), so links there navigate normally.
    document.addEventListener('click', function (e) {
        var card = e.target.closest('.bv-event-row[data-event-key]');
        if (!card) { return; }
        if (e.target.closest('[data-rsvp-key]')) { return; }              // signup button → RSVP handler
        if (e.target.closest('a[href], input, select, textarea')) { return; } // real links / form controls
        e.preventDefault();
        toggle(card);
    });

    // Keyboard: Enter/Space on a focused card toggles it; Esc collapses the open one.
    document.addEventListener('keydown', function (e) {
        if (e.key === 'Enter' || e.key === ' ') {
            var card = e.target.closest && e.target.closest('.bv-event-row[data-event-key]');
            if (card && e.target === card) { e.preventDefault(); toggle(card); }
        } else if (e.key === 'Escape') {
            var expanded = document.querySelector('.bv-event-row.is-expanded');
            if (expanded) { collapse(expanded); try { expanded.focus(); } catch (err) {} }
        }
    });
}());

// ============================================================================
// Dashboard "Slet"/"Slet helt" confirmation popovers ("Arrangørpanel").
// The popover is a native <details> (so it opens and the form submits without
// JS); this progressive enhancement adds the Annullér button, click-outside
// and Esc to close, and a single-open-at-a-time behaviour.
// ============================================================================
(function () {
    'use strict';
    var SEL = 'details.bv-event-dashboard__confirm';

    function closeAll(except) {
        document.querySelectorAll(SEL + '[open]').forEach(function (d) {
            if (d !== except) { d.removeAttribute('open'); }
        });
    }

    document.addEventListener('click', function (e) {
        // Annullér inside a popover closes it (never submits).
        var cancel = e.target.closest('[data-confirm-cancel]');
        if (cancel) {
            e.preventDefault();
            var owner = cancel.closest(SEL);
            if (owner) { owner.removeAttribute('open'); }
            return;
        }
        // Opening one summary collapses the others (after the native toggle).
        var summary = e.target.closest(SEL + ' > summary');
        if (summary) {
            var d = summary.parentNode;
            setTimeout(function () { if (d.open) { closeAll(d); } }, 0);
            return;
        }
        // A click anywhere else closes any open confirm popover.
        if (!e.target.closest(SEL)) { closeAll(null); }
    });

    document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape') { closeAll(null); }
    });
}());

// ============================================================================
// Header account menu (account_self_service) — accessible dropdown on the
// logged-in user chip. Opens on click (or ArrowDown/ArrowUp from the button),
// closes on Escape (focus returns to the button), click-outside, focus-out,
// and item selection. Items are keyboard-navigable (arrows, Home/End). No
// hover behaviour. The chip is a dead <span> when the flag is off — this
// module then finds nothing and does nothing.
// ============================================================================
(function () {
    'use strict';

    function init() {
        var button = document.querySelector('.bv-nav__user--menu');
        var menu = document.getElementById('bv-account-menu');
        if (!button || !menu) { return; }

        function items() {
            return Array.prototype.slice.call(menu.querySelectorAll('[role="menuitem"]'));
        }

        function isOpen() { return !menu.hidden; }

        function open(focusTarget) {
            menu.hidden = false;
            button.setAttribute('aria-expanded', 'true');
            var list = items();
            if (focusTarget === 'first' && list.length) { list[0].focus(); }
            if (focusTarget === 'last' && list.length) { list[list.length - 1].focus(); }
        }

        function close(returnFocus) {
            if (!isOpen()) { return; }
            menu.hidden = true;
            button.setAttribute('aria-expanded', 'false');
            if (returnFocus) { button.focus(); }
        }

        button.addEventListener('click', function () {
            if (isOpen()) { close(false); } else { open(null); }
        });

        button.addEventListener('keydown', function (e) {
            if (e.key === 'ArrowDown') { e.preventDefault(); open('first'); }
            else if (e.key === 'ArrowUp') { e.preventDefault(); open('last'); }
            else if (e.key === 'Escape') { close(true); }
        });

        menu.addEventListener('keydown', function (e) {
            var list = items();
            if (!list.length) { return; }
            var idx = list.indexOf(document.activeElement);
            if (e.key === 'Escape') { e.preventDefault(); close(true); }
            else if (e.key === 'ArrowDown') { e.preventDefault(); list[(idx + 1) % list.length].focus(); }
            else if (e.key === 'ArrowUp') { e.preventDefault(); list[(idx - 1 + list.length) % list.length].focus(); }
            else if (e.key === 'Home') { e.preventDefault(); list[0].focus(); }
            else if (e.key === 'End') { e.preventDefault(); list[list.length - 1].focus(); }
        });

        // Selecting an item closes the menu; navigation proceeds normally.
        menu.addEventListener('click', function (e) {
            var item = e.target instanceof Element ? e.target.closest('[role="menuitem"]') : null;
            if (item) { close(false); }
        });

        // Click-outside and focus-out both dismiss.
        document.addEventListener('click', function (e) {
            if (isOpen() && e.target instanceof Node
                && !menu.contains(e.target) && !button.contains(e.target)) { close(false); }
        });
        document.addEventListener('focusin', function (e) {
            if (isOpen() && e.target instanceof Node
                && !menu.contains(e.target) && !button.contains(e.target)) { close(false); }
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
