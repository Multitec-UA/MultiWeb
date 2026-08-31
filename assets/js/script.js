$(document).ready(function() {
    $(window).scroll(function() {
        var scroll = $(window).scrollTop();

        if (scroll >= 569) {
            $('.navbar').addClass('navbar-fixed-top dark-bar');
        } else {
            $('.navbar').removeClass('navbar-fixed-top dark-bar');
        }
    });

    // Smooth Scroll
    $('a[href*="#"]:not([href="#"])').click(function() {
        if (
            location.pathname.replace(/^\//, '') ==
            this.pathname.replace(/^\//, '') ||
            location.hostname == this.hostname
        ) {
            var target = $(this.hash);
            target = target.length ? target : $('[name=' + this.hash.slice(1) + ']');
            if (target.length) {
                $('html,body').animate({
                        scrollTop: target.offset().top - 30,
                    },
                    1000
                );
                return false;
            }
        }
    });

    // Slider

    $('#workstation-slider').owlCarousel({
        loop: true,
        margin: 30,
        responsive: {
            0: {
                items: 1,
            },
            600: {
                items: 2,
            },
            1000: {
                items: 3,
            },
        },
    });
    $('#expert-slider').owlCarousel({
        loop: true,
        items: 1,
    });

    // The #inscription photo panel used to be sized here, from
    // $('.expert').height() read at this instant. That made the layout depend on
    // whether the webfont had arrived yet (729px vs 761px below 768px), so the
    // page rendered differently on a fast connection than on a slow one. It is
    // CSS now -- flex side by side, a viewport-sized band stacked -- see the
    // #inscription block in style.css. Nothing replaces it here on purpose.

    // Menu bar
    var $toggle = $('.menu');
    var $panel = $('#menu-item');

    function setMenu(open) {
        $toggle.toggleClass('c', open).toggleClass('m', !open);
        $toggle.attr('aria-expanded', open ? 'true' : 'false');
        $toggle.attr('aria-label', open ? 'Cerrar el menú' : 'Abrir el menú');
        $panel.toggleClass('show-menu', open).toggleClass('hide-menu', !open);
    }

    $toggle.click(function(e) {
        e.preventDefault();
        setMenu(!$panel.hasClass('show-menu'));
    });

    // Any choice inside the panel closes it -- every link in there is either an
    // in-page anchor or another page, so leaving it open is never right.
    $panel.find('a').click(function() {
        setMenu(false);
    });

    // Escape closes it, and focus goes back to the control that opened it.
    $(document).keydown(function(e) {
        if (e.key === 'Escape' && $panel.hasClass('show-menu')) {
            setMenu(false);
            $toggle.focus();
        }
    });
});


$(function() { // $(document).ready shorthand
    $('.monster').fadeIn('slow');
});

$(document).ready(function() {

    /* Every time the window is scrolled ... */
    $(window).scroll(function() {

        /* Check the location of each desired element */
        $('.hideme').each(function(i) {

            var bottom_of_object = $(this).position().top + $(this).outerHeight();
            var bottom_of_window = $(window).scrollTop() + $(window).height();

            /* If the object is completely visible in the window, fade it it */
            if (bottom_of_window > bottom_of_object) {

                $(this).animate({ 'opacity': '1' }, 1500);

            }

        });

    });

});

// FAQ
//
// The questions are <p role="button" tabindex="0" aria-expanded>. They were plain
// <p> with a click listener, which meant a keyboard or switch user could not open
// a single one of them -- including "¿Cómo puedo unirme?", the answer most likely
// to decide whether somebody pays the 12 euros. Audit item 2.4.
const faq = document.getElementsByClassName("faq-question");

function toggleFaq(question) {
    const body = question.nextElementSibling;
    const open = body.style.display !== "block";
    question.classList.toggle("faq-active", open);
    body.style.display = open ? "block" : "none";
    question.setAttribute("aria-expanded", open ? "true" : "false");
}

for (let i = 0; i < faq.length; i++) {
    faq[i].addEventListener("click", function () {
        toggleFaq(this);
    });
    faq[i].addEventListener("keydown", function (e) {
        // Enter and Space are what a native <button> answers to, and role="button"
        // promises exactly that.
        if (e.key === "Enter" || e.key === " " || e.key === "Spacebar") {
            e.preventDefault();
            toggleFaq(this);
        }
    });
}
// ===========================================================================
// The events wheel (#events)
// ===========================================================================
// Vanilla on purpose. jQuery is loaded on this page and this could have used it, but a
// scroll handler that runs on every frame is the one place on the site where the wrapper
// costs something measurable, and there is nothing here jQuery would have made shorter.
//
// It does three jobs, and it is worth being precise about why each of them is here in the
// browser rather than in i18n/build.py, which renders everything else on this page:
//
//   * past / next / happening-now, and the countdown, depend on TODAY. src/*.html is
//     generated and committed, and tests/verify.sh fails when regenerating it would
//     change a byte, so a page with "24 days to go" baked into it would be stale the
//     next morning and red in CI by lunchtime. The dates come from data-start/data-end,
//     the words come from data-* on .ev-wheel (so they stay in i18n/strings.json like
//     every other sentence on the site), and the arithmetic happens here.
//
//   * the wheel itself is one number per card: --t, where the card sits relative to the
//     middle of the rail, -1 to +1. Every rotation, depth and arc in the CSS is a
//     function of it. With this script absent both --t and --a stay 0 and the section is
//     a flat, ordered, entirely usable row of cards.
//
//   * the two arrows are created disabled and hidden in the markup and only revealed
//     here, because a button that needs JavaScript to do anything should not be on the
//     page when there is none.
//
// Nothing here sets a width, a height or a position. The layout is CSS, at every width,
// which is the rule group 15 of tests/verify.sh exists to keep.
(function () {
    var wheel = document.querySelector('.ev-wheel');
    if (!wheel) return;

    var scroller = wheel.querySelector('.ev-scroller');
    var cards = Array.prototype.slice.call(wheel.querySelectorAll('.ev-card'));
    if (!scroller || !cards.length) return;

    var L = {
        next: wheel.getAttribute('data-pill-next'),
        past: wheel.getAttribute('data-pill-past'),
        days: wheel.getAttribute('data-cd-days'),
        tomorrow: wheel.getAttribute('data-cd-tomorrow'),
        today: wheel.getAttribute('data-cd-today'),
        running: wheel.getAttribute('data-cd-running'),
        tbc: wheel.getAttribute('data-cd-tbc')
    };

    // "2026-11-13T17:00" is local time in Europe/Madrid, which is also the timezone of
    // essentially everyone reading this page. new Date(string) on a form with no zone
    // suffix is parsed as local time, which is exactly what is wanted -- but only in the
    // date-time form, so it is spelled out rather than trusted.
    // Three shapes, because a future event often has only a month: 2026-10,
    // 2026-10-15 and 2026-10-15T17:00 are all valid. A month resolves to its first day,
    // which is only ever used for ordering and for the has-it-happened test.
    function at(value) {
        var m = /^(\d{4})-(\d{2})(?:-(\d{2}))?(?:T(\d{2}):(\d{2}))?$/.exec(value || '');
        if (!m) return null;
        return new Date(+m[1], +m[2] - 1, +(m[3] || 1), +(m[4] || 0), +(m[5] || 0), 0, 0);
    }

    // The end of a month-precision event is the end of that month, not its first day —
    // otherwise "OCTUBRE 2026" would go grey on the 2nd of October.
    function endOf(card) {
        var raw = card.getAttribute('data-end') || card.getAttribute('data-start') || '';
        var d = at(raw);
        if (d && raw.length === 7) return new Date(d.getFullYear(), d.getMonth() + 1, 0, 23, 59);
        return d;
    }

    // Whole days between two calendar days, counted from midnight to midnight. Not
    // (b - a) / 86400000: across the October clock change that is 24.04 days and rounds
    // to the wrong answer for exactly the week the association runs its autumn events.
    function daysUntil(from, to) {
        var a = new Date(from.getFullYear(), from.getMonth(), from.getDate());
        var b = new Date(to.getFullYear(), to.getMonth(), to.getDate());
        return Math.round((b - a) / 86400000);
    }

    function label(days) {
        // 0 is today and 1 is tomorrow, so the plural form below is only ever asked
        // for numbers that are actually plural in both languages.
        if (days <= 0) return L.today;
        if (days === 1) return L.tomorrow;
        return L.days.replace('%d', days);
    }

    // ---- pass 1: what has happened, what has not, and what is next -----------------
    var featured = null;

    function markStates() {
        var now = new Date();
        featured = null;

        cards.forEach(function (card) {
            var start = at(card.getAttribute('data-start'));
            if (!start) return;
            var end = endOf(card) || start;
            var state = card.querySelector('.ev-state');
            var media = card.querySelector('.ev-media');

            card.classList.remove('is-past', 'is-next', 'is-running');
            var old = card.querySelector('.ev-pill');
            if (old) old.parentNode.removeChild(old);

            var pill = null;
            if (now > end) {
                card.classList.add('is-past');
                pill = L.past;
                if (state) { state.textContent = ''; state.hidden = true; }
            } else {
                if (!featured) featured = card;
                if (now >= start) {
                    card.classList.add('is-running');
                    if (state) { state.textContent = L.running; state.hidden = false; }
                } else if (state) {
                    // Counting down to a day nobody has committed to is a lie with a
                    // number attached. A tentative date says so instead.
                    state.textContent = card.getAttribute('data-tentative')
                        ? L.tbc : label(daysUntil(now, start));
                    state.hidden = false;
                }
            }

            if (featured === card && !card.classList.contains('is-running')) {
                card.classList.add('is-next');
                pill = L.next;
            }

            if (pill && media) {
                var el = document.createElement('p');
                el.className = 'ev-pill';
                el.textContent = pill;
                media.appendChild(el);
            }
        });
    }

    // ---- pass 2: the wheel ----------------------------------------------------------
    // --t is read from LAYOUT (offsetLeft), never from getBoundingClientRect. The cards
    // are 3D-transformed by the value this sets, so measuring their painted rectangle
    // here would feed the transform back into its own input and the strip would shiver.
    var ticking = false;

    function turn() {
        ticking = false;
        var mid = scroller.scrollLeft + scroller.clientWidth / 2 + scroller.offsetLeft;
        var reach = scroller.clientWidth / 2 + cards[0].offsetWidth / 2;
        if (reach <= 0) return;
        for (var i = 0; i < cards.length; i++) {
            var c = cards[i];
            var t = (c.offsetLeft + c.offsetWidth / 2 - mid) / reach;
            t = Math.max(-1, Math.min(1, t));
            c.style.setProperty('--t', t.toFixed(3));
            c.style.setProperty('--a', Math.abs(t).toFixed(3));
        }
        syncNav();
    }

    function schedule() {
        if (ticking) return;
        ticking = true;
        window.requestAnimationFrame(turn);
    }

    // ---- the two arrows -------------------------------------------------------------
    var prev = wheel.querySelector('.ev-prev');
    var next = wheel.querySelector('.ev-next');

    function step(direction) {
        var by = cards[0].offsetWidth + 28;   // one card plus the gap in .ev-track
        scroller.scrollLeft += direction * by;
    }

    function syncNav() {
        if (!prev || !next) return;
        var max = scroller.scrollWidth - scroller.clientWidth;
        prev.disabled = scroller.scrollLeft <= 1;
        next.disabled = scroller.scrollLeft >= max - 1;
    }

    if (prev && next) {
        prev.hidden = false;
        next.hidden = false;
        prev.addEventListener('click', function () { step(-1); });
        next.addEventListener('click', function () { step(1); });
    }

    // ---- start ----------------------------------------------------------------------
    markStates();

    // Open on the next event rather than on the oldest one. The instant hop has to
    // dodge `scroll-behavior: smooth`, which would otherwise animate the page's first
    // paint sideways for half a second.
    var target = featured || cards[cards.length - 1];
    var behaviour = scroller.style.scrollBehavior;
    scroller.style.scrollBehavior = 'auto';
    scroller.scrollLeft = target.offsetLeft + target.offsetWidth / 2
        - scroller.offsetLeft - scroller.clientWidth / 2;
    scroller.style.scrollBehavior = behaviour;

    turn();
    scroller.addEventListener('scroll', schedule, { passive: true });
    window.addEventListener('resize', schedule);

    // A visitor who leaves the page open overnight should not be told an event that
    // happened this morning is still three hours away. Cheap, and it costs nothing while
    // the tab is in the background.
    window.setInterval(markStates, 10 * 60 * 1000);
})();
