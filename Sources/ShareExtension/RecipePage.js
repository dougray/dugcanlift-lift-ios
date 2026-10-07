// Safari runs this on the page at the moment it is shared to LIFT, and hands
// the result to the share extension. It returns the page's address and the
// text of every application/ld+json block -- the schema.org data recipe sites
// publish. Safari already has the page on screen; LIFT requests nothing.
var RecipePage = function () {};
RecipePage.prototype = {
  run: function (args) {
    var blocks = [].slice.call(document.querySelectorAll('script[type="application/ld+json"]'))
      .map(function (s) { return s.textContent; });
    args.completionFunction({ url: document.URL, jsonld: blocks });
  }
};
var ExtensionPreprocessingJS = new RecipePage;
