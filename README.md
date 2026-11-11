# openlibrary.el

An [Open Library](https://openlibrary.org) API client for Emacs, built on
[plz.el](https://github.com/alphapapa/plz.el).

It covers the Search, Works, Editions, Authors, Subjects, Books and Covers
APIs.  Every function is synchronous by default and returns decoded JSON;
pass `:then` to make the request asynchronous.

## Installation

`openlibrary.el` depends on [plz.el](https://github.com/alphapapa/plz.el)
(which uses `curl`).  Put both in your `load-path` and:

```elisp
(require 'openlibrary)
```

## Usage

### Synchronous

```elisp
(openlibrary-search "emacs" :limit 5 :fields '(key title author_name))
;; => (("numFound" . 86) ("start" . 0) ... ("docs" (("key" . "/works/OL478363W") ...)))

(let ((work (openlibrary-work "OL45804W")))
  (list (alist-get "title" work nil nil #'equal)
        (openlibrary-description work)))
;; => ("Fantastic Mr Fox" "The main character of ...")

(openlibrary-edition-by-isbn "978-0-14-032872-1")
(openlibrary-author-works "/authors/OL23919A" :limit 10)
```

The `:olid` arguments accept a bare OLID (`"OL45804W"`), a key
(`"/works/OL45804W"`) or an Open Library URL.

### Asynchronous

```elisp
(openlibrary-search
 "emacs"
 :limit 5
 :then (lambda (result)
         (message "%d hits" (alist-get "numFound" result nil nil #'equal)))
 :else (lambda (err)
         (message "Open Library request failed: %S" err)))
```

Asynchronous calls return the curl process; `:then` is called with the
decoded response and `:else` with a `plz-error`.

### Covers

```elisp
(openlibrary-cover-url "9780140328721" :type 'isbn :size 'L)
;; => "https://covers.openlibrary.org/b/isbn/9780140328721-L.jpg?default=false"

(openlibrary-download-cover "OL7353617M" "/tmp/cover.jpg" :type 'olid)
```

`openlibrary-cover-url` adds `?default=false` unless `:default` is non-nil,
so that a missing cover yields HTTP 404 instead of a blank image.

## Data representation

Responses are decoded into alists with **string** keys, JSON arrays become
lists, and JSON `null` and `false` both become `nil`.  For example:

```elisp
(openlibrary-work "OL45804W")
;; => (("title" . "Fantastic Mr Fox")
;;     ("key" . "/works/OL45804W")
;;     ("authors" (("author" ("key" . "/authors/OL34184A")) ...))
;;     ...)
```

Use `alist-get` with `#'equal` for string keys:

```elisp
(alist-get "title" work nil nil #'equal)
```

Descriptions returned by Open Library are sometimes strings and sometimes
`(("type" . ...) ("value" . ...))` alists; `openlibrary-description`
normalizes both to a string.

## Endpoints

| Function | Endpoint | Notes |
|---|---|---|
| `openlibrary-search` | `/search.json` | Full-text search; `:title`, `:author`, `:subject`, `:place`, `:person`, `:publisher`, `:isbn`, `:oclc`, `:lccn`, `:olid`, `:lang`, `:fields`, `:sort`, `:page`, `:limit` |
| `openlibrary-search-authors` | `/search/authors.json` | `:limit`, `:offset` |
| `openlibrary-search-inside` | `/search/inside.json` | Full-text search inside scanned books; `:page`, `:limit` |
| `openlibrary-work` | `/works/OLID.json` | Work metadata |
| `openlibrary-work-editions` | `/works/OLID/editions.json` | `:limit`, `:offset` |
| `openlibrary-work-ratings` | `/works/OLID/ratings.json` | Average and per-value rating counts |
| `openlibrary-work-bookshelves` | `/works/OLID/bookshelves.json` | Want to read / reading / read counts |
| `openlibrary-edition` | `/books/OLID.json` | Edition metadata |
| `openlibrary-edition-by-isbn` | `/isbn/ISBN.json` | Follows the redirect to the edition |
| `openlibrary-author` | `/authors/OLID.json` | Author metadata |
| `openlibrary-author-works` | `/authors/OLID/works.json` | `:limit`, `:offset` |
| `openlibrary-subject` | `/subjects/SUBJECT.json` | `:limit`, `:offset`, `:published-in`, `:ebooks` |
| `openlibrary-books` | `/api/books` | Books API; `:jscmd` is `"data"` or `"viewapi"` |
| `openlibrary-cover-url` | `covers.openlibrary.org` | Build a cover URL; `:type`, `:size`, `:default` |
| `openlibrary-download-cover` | `covers.openlibrary.org` | Download a cover to a file |

Every request function accepts `:then` and `:else` for asynchronous use.
See each function's docstring for the shape of the returned data.

## Errors

Synchronous requests signal `plz-error` (more precisely `plz-http-error` or
`plz-curl-error`) on failure:

```elisp
(condition-case err
    (openlibrary-work "OL00000000W")
  (plz-error
   (message "Request failed: %S" (plz-error-response err))))
```

Asynchronous requests call `:else` with a `plz-error` instead; if `:else` is
omitted, the error is stored on the process and not signaled.

## Customization

| Variable | Default | Purpose |
|---|---|---|
| `openlibrary-base-url` | `https://openlibrary.org` | API base URL |
| `openlibrary-covers-base-url` | `https://covers.openlibrary.org` | Covers service base URL |
| `openlibrary-user-agent` | `openlibrary.el/VERSION (Emacs VERSION)` | `User-Agent` header |
| `openlibrary-connect-timeout` | `10` | Connection timeout in seconds |
| `openlibrary-timeout` | `30` | Total request timeout in seconds |

Open Library asks API clients to identify themselves; consider setting
`openlibrary-user-agent` to include your e-mail address or project URL.

## Troubleshooting

On very new Emacs snapshots (e.g. Emacs 32 / `emacs-git`), loading `plz.el`
from source can fail with an eager macro-expansion error such as:

```
Warning: Optimization failure for cl--block-wrapper ...
Eager macro-expansion failure: (void-variable byte-compile-current-buffer)
```

That is a regression in the Emacs snapshot, not in `openlibrary.el`.  Loading
the byte-compiled `plz.elc` avoids it, so byte-compile plz once:

```sh
emacs -Q --batch -f batch-byte-compile /path/to/plz.el/plz.el
```

## License

GPL-3.0-or-later.  See <https://www.gnu.org/licenses/gpl-3.0.html>.
