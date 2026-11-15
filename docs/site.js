// French / English switch. French is in the HTML; this only flips <html lang>. Nothing is sent anywhere.
(function () {
  var root = document.documentElement;
  var titles = {
    fr: 'Buntu — Lecteur IPTV et média neutre',
    en: 'Buntu — A neutral IPTV and media player'
  };

  function saved() {
    try { return localStorage.getItem('buntu-lang'); } catch (e) { return null; }
  }

  function apply(lang) {
    root.lang = lang;
    document.title = titles[lang];
    try { localStorage.setItem('buntu-lang', lang); } catch (e) { /* private mode: the choice is not kept */ }
  }

  var first = saved() || ((navigator.language || 'fr').slice(0, 2) === 'fr' ? 'fr' : 'en');
  if (first !== root.lang) apply(first);

  var button = document.getElementById('lang');
  if (button) {
    button.addEventListener('click', function () {
      apply(root.lang === 'fr' ? 'en' : 'fr');
    });
  }
})();
