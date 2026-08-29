/* The Lixsa chat widget — loaded late, on purpose (audit item 4.4).
 *
 * It is NOT dead weight, which is the first thing that had to be established before
 * touching it. Measured 2026-08-29 against a local build of this repo: the bubble opens,
 * https://task.lixsa.ai/webhook/webchat/conversation?lixsaId=55e502ac-... answers 200, and
 * the panel greets the visitor in Spanish. It is configured, live and answering, so it
 * stays.
 *
 * Nor is its bubble in the way, which is the other thing the audit claimed. Measured at
 * 390 x 844: the drawn bubble is 64 x 64 inset 24px from both screen edges — the geometry
 * every chat widget on the web has — and across 103 scroll positions down an 11,158px page
 * it passes over a link at 11 of them, all but one of those being an <a> wrapping a logo or
 * a news thumbnail. It never covers MÁS INFORMACIÓN E INSCRIPCIÓN. (An earlier run said it
 * did; that run measured .lixsa-webchat, the 64x64 FIXED wrapper pinned to right:0/bottom:0,
 * and the bubble inside it is offset 24px up and left of that box. Measure the element that
 * is drawn, not the one that positions it.) So nothing here restyles their DOM.
 *
 * What WAS wrong is WHEN it loaded. This file used to inject the script tag the instant it
 * was parsed, so every single visit fetched https://chat.lixsa.ai/lixsa-chat.umd.cjs —
 * 265,065 bytes measured, a quarter of the whole homepage — in competition with the
 * association's own images and fonts, for a bubble in the bottom-right corner that most
 * visitors never press. Nothing above the fold depends on it.
 *
 * So: load it on the first sign of a visitor who might use it (a tap, a key, a scroll), and
 * otherwise when the browser is idle after everything else has finished. Either path leads
 * to the same guarded load(), so the widget always turns up — it just never gets in front
 * of the page any more.
 */
(function (d, w) {
    var loaded = false;
    var events = ['pointerdown', 'keydown', 'touchstart', 'scroll'];

    function load() {
        if (loaded) { return; }
        loaded = true;
        events.forEach(function (e) { w.removeEventListener(e, load); });

        var s = d.createElement('script');
        s.src = 'https://chat.lixsa.ai/lixsa-chat.umd.cjs';
        s.async = true;
        s.setAttribute('data-language', 'es');
        s.setAttribute('data-welcome-message', '¡Hola! ¿Cómo puedo ayudarte?');
        s.setAttribute('data-lixsa-id', '55e502ac-38be-4b52-a203-0e4bde48746f');
        /* --lixsa-primary was #ba1616, which is not a colour this association owns. The
           brandbook primary is #a30006 and it is the red every other red on this page is. */
        s.setAttribute('data-theme', '{"--lixsa-primary":"#a30006","--lixsa-primary-gradient":"linear-gradient(135deg, #a30006, #d11a21)","--lixsa-text":"#333333","--lixsa-text-user":"#ffffff","--lixsa-text-light":"#555555","--lixsa-text-light-secondary":"#dddddd","--lixsa-bg":"#f5f5f5","--lixsa-bg-secondary":"#ffffff","--lixsa-shadow-sm":"0 1px 3px rgba(0, 0, 0, 0.05), 0 1px 2px rgba(0, 0, 0, 0.03)","--lixsa-shadow-md":"0 4px 6px -1px rgba(0, 0, 0, 0.08), 0 2px 4px -1px rgba(0, 0, 0, 0.04)","--lixsa-shadow-lg":"0 10px 25px -5px rgba(0, 0, 0, 0.1), 0 8px 10px -6px rgba(0, 0, 0, 0.05)","--lixsa-radius-sm":"0.375rem","--lixsa-radius-md":"0.5rem","--lixsa-radius-lg":"1rem","--lixsa-radius-full":"9999px","--lixsa-transition":"all 0.2s cubic-bezier(0.4, 0, 0.2, 1)","--lixsa-font-family":"-apple-system, BlinkMacSystemFont, \'Segoe UI\', Roboto, Helvetica, Arial, sans-serif"}');

        var first = d.getElementsByTagName('script')[0];
        if (first && first.parentNode) { first.parentNode.insertBefore(s, first); }
        else { d.head.appendChild(s); }
    }

    events.forEach(function (e) {
        w.addEventListener(e, load, { passive: true, once: true });
    });

    /* The belt to that pair of braces: a visitor who lands and does nothing at all still
       gets the bubble, once the browser has nothing better to do. */
    function idle() {
        if (w.requestIdleCallback) { w.requestIdleCallback(load, { timeout: 4000 }); }
        else { w.setTimeout(load, 2500); }
    }
    if (d.readyState === 'complete') { idle(); } else { w.addEventListener('load', idle); }
})(document, window);
