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
                showConfirmation(result.data.message || 'Tak! Din fejlrapport er modtaget.');
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

    function showConfirmation(message) {
        var toast = document.createElement('div');
        toast.className = 'bv-bug-report-toast';
        toast.setAttribute('role', 'status');
        toast.setAttribute('aria-live', 'polite');
        toast.textContent = message;
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

    // Calendar filter buttons (exclusive: one active at a time, no deselect)
    document.querySelectorAll('.bv-filter-btn[data-filter]').forEach(function(btn) {
        btn.addEventListener('click', function() {
            var group = this.dataset.filter;
            var rows = document.querySelectorAll('.bv-event-row[data-group]');

            // Clear all, activate only this one
            document.querySelectorAll('.bv-filter-btn[data-filter]').forEach(function(b) { b.classList.remove('is-active'); });
            this.classList.add('is-active');

            // Show matching rows
            rows.forEach(function(row) {
                if (group === 'all' || row.dataset.group === group) {
                    row.style.display = '';
                } else {
                    row.style.display = 'none';
                }
            });
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
