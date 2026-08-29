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