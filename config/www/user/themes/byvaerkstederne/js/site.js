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
