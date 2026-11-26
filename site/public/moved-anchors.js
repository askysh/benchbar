// The old address of a page that was split (#169): when its anchor is on
// another page now, go there and keep the anchor. A redirect in the site
// config cannot carry an anchor. The page loads a data file from /moved/
// first, which sets window.MOVED_ANCHORS (page path, then anchor, then the
// new page). scripts/docs-links.py checks every entry against the headings.
(function () {
  var moved = window.MOVED_ANCHORS || {};
  var page = moved[location.pathname.replace(/\/?$/, '/')];
  var id = decodeURIComponent(location.hash.slice(1));
  if (page && id && page[id] && !document.getElementById(id)) {
    location.replace(page[id] + '#' + encodeURIComponent(id));
  }
})();
