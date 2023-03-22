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

    // Popup

    $('.popup-youtube, .popup-vimeo, .popup-gmaps').magnificPopup({
        disableOn: 700,
        type: 'iframe',
        mainClass: 'mfp-fade',
        removalDelay: 160,
        preloader: false,
        fixedContentPos: false,
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

    // height

    var h = $('.expert').height();
    $('.expert .col-sm-6 div').height(function(index, height) {
        return h;
    });

    // Menu bar
    $('.menu').click(function() {
        $(this).toggleClass('m c');
        $('.menu span').toggleClass('ion-navicon ion-android-close');
        $('#menu-item').toggleClass('show-menu hide-menu');
    });

    $('#menu-item a').click(function() {
        $('.menu').toggleClass('c m');
        $('.menu span').toggleClass('ion-navicon ion-android-close');
        $('#menu-item').toggleClass('show-menu hide-menu');
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

//FAQ
const faq = document.getElementsByClassName("faq-question");
let i;

for (i = 0; i < faq.length; i++) {
    faq[i].addEventListener("click", function () {
        /* Toggle between adding and removing the "active" class,
        to highlight the button that controls the panel */
        this.classList.toggle("faq-active");

        /* Toggle between hiding and showing the active panel */
        var body = this.nextElementSibling;
        if (body.style.display === "block") {
            body.style.display = "none";
        } else {
            body.style.display = "block";
        }
    });
}