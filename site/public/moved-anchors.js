// The old address of a page that was split (#169): when its anchor is on
// another page now, go there and keep the anchor. A redirect in the site
// config cannot carry an anchor. The page loads a data file from /moved/
// first, which sets window.MOVED_ANCHORS (page path, then anchor, then the
// new page). scripts/docs-links.py checks every entry against the headings.
// Only own entries count: a hash or a path that names a built-in property
// (#constructor, #__proto__) is no anchor that moved.
(function () {
  var own = function (o, k) { return Object.prototype.hasOwnProperty.call(o, k); };
  var moved = window.MOVED_ANCHORS || {};
  var path = location.pathname.replace(/\/?$/, '/');
  if (!own(moved, path)) return;
  var page = moved[path];
  var id;
  try { id = decodeURIComponent(location.hash.slice(1)); } catch (e) { return; }
  if (id && own(page, id) && typeof page[id] === 'string' && !document.getElementById(id)) {
    location.replace(page[id] + '#' + encodeURIComponent(id));
  }
})();
