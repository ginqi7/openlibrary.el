;;; openlibrary.el --- Open Library API client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Qiqi Jin

;; Author: Qiqi Jin <ginqi7@gmail.com>
;; Maintainer: Qiqi Jin <ginqi7@gmail.com>
;; URL: https://github.com/ginqi7/openlibrary.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (plz "0.9"))
;; Keywords: comm, data, hypermedia
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; An Open Library (https://openlibrary.org) API client built on
;; plz.el (https://github.com/alphapapa/plz.el).
;;
;; Every request function is synchronous by default and returns the
;; decoded JSON response:
;;
;;   (openlibrary-search "emacs" :limit 5 :fields '(key title author_name))
;;   (openlibrary-work "OL45804W")
;;   (openlibrary-edition-by-isbn "9780140328721")
;;   (openlibrary-author-works "OL23919A" :limit 10)
;;   (openlibrary-subject "science_fiction" :limit 10)
;;
;; Pass a function as :THEN to make the request asynchronous; :ELSE
;; is then called with a `plz-error' if the request fails:
;;
;;   (openlibrary-search
;;    "emacs"
;;    :limit 5
;;    :then (lambda (result)
;;            (message "%d hits"
;;                     (alist-get "numFound" result nil nil #'equal)))
;;    :else (lambda (err) (message "Request failed: %S" err)))
;;
;; Responses are JSON objects decoded into alists with string keys
;; (\"key\", \"title\", ...), arrays into lists, and both null and
;; false into nil.  See the README for the supported endpoints and
;; for notes on the data returned by each one.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url-util)

(require 'plz)

(defconst openlibrary-version "0.1.0"
  "Version of the openlibrary.el package.")

(defgroup openlibrary nil
  "Open Library API client."
  :group 'comm
  :prefix "openlibrary-")

(defcustom openlibrary-base-url "https://openlibrary.org"
  "Base URL of the Open Library API."
  :group 'openlibrary
  :type 'string)

(defcustom openlibrary-covers-base-url "https://covers.openlibrary.org"
  "Base URL of the Open Library covers service."
  :group 'openlibrary
  :type 'string)

(defcustom openlibrary-user-agent
  (format "openlibrary.el/%s (Emacs %s)" openlibrary-version emacs-version)
  "User-Agent header sent with every request.
Open Library asks API clients to identify themselves; see
URL `https://openlibrary.org/developers/api'."
  :group 'openlibrary
  :type 'string)

(defcustom openlibrary-connect-timeout 10
  "Seconds to wait for a connection to be established."
  :group 'openlibrary
  :type 'number)

(defcustom openlibrary-timeout 30
  "Seconds to wait for a complete response."
  :group 'openlibrary
  :type 'number)

;;;; Helpers

(defun openlibrary--param (value)
  "Return VALUE as a query string value."
  (format "%s" value))

(defun openlibrary--query (params)
  "Return PARAMS as a list suitable for `url-build-query-string'.
PARAMS is an alist of (KEY . VALUE) pairs.  Pairs whose value is
nil are dropped; list values become repeated parameters."
  (delq nil
        (mapcar (lambda (pair)
                  (let ((value (cdr pair)))
                    (cond ((null value) nil)
                          ((listp value)
                           (cons (car pair)
                                 (mapcar #'openlibrary--param value)))
                          (t (list (car pair) (openlibrary--param value))))))
                params)))

(defun openlibrary--url (path &optional params)
  "Return the absolute URL for PATH with query PARAMS.
PARAMS is an alist of (KEY . VALUE) pairs, or nil."
  (let ((query (and params
                    (url-build-query-string (openlibrary--query params)))))
    (concat (string-remove-suffix "/" openlibrary-base-url)
            (unless (string-prefix-p "/" path) "/")
            path
            (unless (or (null query) (string-empty-p query))
              (concat "?" query)))))

(defun openlibrary--csv (value)
  "Return VALUE as a comma-separated string, or nil.
VALUE may be nil, a string, or a list of strings and symbols."
  (pcase value
    ('nil nil)
    ((pred stringp) value)
    ((pred listp) (mapconcat (lambda (item) (format "%s" item)) value ","))
    (_ (format "%s" value))))

(defun openlibrary--json-read ()
  "Read the JSON in the current buffer into alists with string keys."
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'string)
        (json-null nil)
        (json-false nil))
    (json-read)))

(defun openlibrary--headers ()
  "Return the HTTP headers sent with every request."
  `(("User-Agent" . ,openlibrary-user-agent)
    ("Accept" . "application/json")))

;;;; Core request

(cl-defun openlibrary--request (path &optional params (then 'sync) else)
  "Request PATH from Open Library with query PARAMS.
PARAMS is an alist of (KEY . VALUE) pairs, or nil.

When THEN is `sync', the request is synchronous: the decoded JSON
body is returned and a `plz-error' is signaled on failure.

When THEN is a function, the request is asynchronous: the curl
process is returned, THEN is called with the decoded JSON body on
success, and ELSE is called with a `plz-error' on failure.

See `openlibrary--url' for how PARAMS is encoded."
  (unless (or (eq then 'sync) (functionp then))
    (user-error "THEN must be `sync' or a function"))
  (plz 'get (openlibrary--url path params)
    :headers (openlibrary--headers)
    :connect-timeout openlibrary-connect-timeout
    :timeout openlibrary-timeout
    :as #'openlibrary--json-read
    :then then
    :else else))

;;;; Data helpers

(defun openlibrary-olid (key)
  "Return the bare OLID contained in KEY.
KEY may be an OLID such as \"OL45804W\", a key such as
\"/works/OL45804W\", or an Open Library URL."
  (let ((key (car (last (split-string (string-trim (format "%s" key))
                                      "/" t)))))
    (string-remove-suffix ".json" key)))

(defun openlibrary--olid (id)
  "Return ID as a URL path segment containing a bare OLID."
  (url-hexify-string (openlibrary-olid id)))

(defun openlibrary--isbn (isbn)
  "Return ISBN normalized for use in an Open Library URL."
  (let ((isbn (upcase (string-trim (format "%s" isbn)))))
    (replace-regexp-in-string "[^0-9X]" "" (string-remove-prefix "ISBN:" isbn))))

(defun openlibrary-description (object)
  "Return the plain text description stored in OBJECT.
Open Library returns descriptions either as strings or as
\(TYPE . VALUE) alists; both forms are handled."
  (let ((description (alist-get "description" object nil nil #'equal)))
    (cond ((null description) nil)
          ((stringp description) description)
          ((listp description)
           (or (alist-get "value" description nil nil #'equal)
               description))
          (t (format "%s" description)))))

;;;; Search API

(cl-defun openlibrary-search (query
                              &key title author subject place person publisher
                              isbn oclc lccn olid lang fields sort page limit
                              (then 'sync) else)
  "Search Open Library for QUERY and return the result as an alist.

QUERY is the full-text query, sent as the \"q\" parameter.  TITLE,
AUTHOR, SUBJECT, PLACE, PERSON and PUBLISHER restrict the results
to matching titles, authors, subjects, places, people and
publishers.  ISBN, OCLC, LCCN and OLID restrict the results to
matching identifiers, e.g. \"ISBN:9780140328721\".  LANG restricts
the results to the given language code, e.g. \"eng\".

FIELDS lists the fields to return, as a list or a comma-separated
string.  SORT is the sort order, e.g. \"new\", \"old\", \"random\",
\"key\", \"title\", \"author\", \"editions\", \"ratings\" or
\"readinglog\".  PAGE is the page number, starting at 1, and LIMIT
the number of results per page.

The response is an alist with keys such as \"numFound\", \"start\"
and \"docs\"; each element of \"docs\" is an alist describing one
work (for example \"key\", \"title\", \"author_name\",
\"first_publish_year\", \"cover_i\" and \"edition_count\").

Return the decoded response synchronously; when THEN is a function,
return the curl process instead, call THEN with the response, and
call ELSE with a `plz-error' if the request fails.  See
`openlibrary--request'."
  (openlibrary--request
   "/search.json"
   `(("q" . ,query)
     ("title" . ,title)
     ("author" . ,author)
     ("subject" . ,subject)
     ("place" . ,place)
     ("person" . ,person)
     ("publisher" . ,publisher)
     ("isbn" . ,isbn)
     ("oclc" . ,oclc)
     ("lccn" . ,lccn)
     ("olid" . ,olid)
     ("lang" . ,lang)
     ("fields" . ,(openlibrary--csv fields))
     ("sort" . ,sort)
     ("page" . ,page)
     ("limit" . ,limit))
   then else))

(cl-defun openlibrary-search-authors (query &key limit offset (then 'sync) else)
  "Search Open Library authors for QUERY.
LIMIT is the maximum number of results and OFFSET the number of
results to skip.

The response is an alist with keys \"numFound\", \"start\" and
\"docs\"; each doc has keys such as \"key\", \"name\",
\"birth_date\", \"top_work\", \"work_count\" and \"top_subjects\".

Return the decoded response synchronously; when THEN is a function,
return the curl process instead, call THEN with the response, and
call ELSE with a `plz-error' if the request fails.  See
`openlibrary--request'."
  (openlibrary--request
   "/search/authors.json"
   `(("q" . ,query)
     ("limit" . ,limit)
     ("offset" . ,offset))
   then else))

(cl-defun openlibrary-search-inside (query &key page limit (then 'sync) else)
  "Full-text search inside the books scanned by the Internet Archive.
QUERY is the text to search for, PAGE the result page starting at
1 and LIMIT the number of results per page.

The response is an alist with keys \"hits\" and \"took\"; \"hits\"
contains \"total\" and \"hits\", the latter being a list of matches
with keys such as \"fields\", \"highlight\" and \"edition\".

Return the decoded response synchronously; when THEN is a function,
return the curl process instead, call THEN with the response, and
call ELSE with a `plz-error' if the request fails.  See
`openlibrary--request'."
  (openlibrary--request
   "/search/inside.json"
   `(("q" . ,query)
     ("page" . ,page)
     ("limit" . ,limit))
   then else))

;;;; Works API

(cl-defun openlibrary-work (olid &key (then 'sync) else)
  "Return the work identified by OLID.
OLID may be a bare OLID such as \"OL45804W\", a key such as
\"/works/OL45804W\" or an Open Library URL.

The response is an alist with keys such as \"key\", \"title\",
\"description\", \"subjects\", \"covers\", \"first_publish_date\",
\"authors\", \"links\", \"subject_places\" and \"subject_times\".

Return the decoded response synchronously; when THEN is a function,
return the curl process instead, call THEN with the response, and
call ELSE with a `plz-error' if the request fails.  See
`openlibrary--request'."
  (openlibrary--request
   (format "/works/%s.json" (openlibrary--olid olid))
   nil then else))

(cl-defun openlibrary-work-editions (olid &key limit offset (then 'sync) else)
  "Return the editions of the work identified by OLID.
LIMIT is the maximum number of editions and OFFSET the number of
editions to skip.

The response is an alist with keys \"size\", \"links\" and
\"entries\"; each entry is an edition object as returned by
`openlibrary-edition'.

Return the decoded response synchronously; when THEN is a function,
return the curl process instead, call THEN with the response, and
call ELSE with a `plz-error' if the request fails.  See
`openlibrary--request'."
  (openlibrary--request
   (format "/works/%s/editions.json" (openlibrary--olid olid))
   `(("limit" . ,limit)
     ("offset" . ,offset))
   then else))

(cl-defun openlibrary-work-ratings (olid &key (then 'sync) else)
  "Return the ratings of the work identified by OLID.
The response is an alist with keys \"summary\" (\"average\",
\"count\" and \"sortable\") and \"counts\" (the number of ratings
for each value from \"1\" to \"5\").

Return the decoded response synchronously; when THEN is a function,
return the curl process instead, call THEN with the response, and
call ELSE with a `plz-error' if the request fails.  See
`openlibrary--request'."
  (openlibrary--request
   (format "/works/%s/ratings.json" (openlibrary--olid olid))
   nil then else))

(cl-defun openlibrary-work-bookshelves (olid &key (then 'sync) else)
  "Return the bookshelf counts of the work identified by OLID.
The response is an alist with a single key \"counts\" whose value
is an alist keyed by \"want_to_read\", \"currently_reading\",
\"already_read\" and \"stopped_reading\".

Return the decoded response synchronously; when THEN is a function,
return the curl process instead, call THEN with the response, and
call ELSE with a `plz-error' if the request fails.  See
`openlibrary--request'."
  (openlibrary--request
   (format "/works/%s/bookshelves.json" (openlibrary--olid olid))
   nil then else))

;;;; Editions API

(cl-defun openlibrary-edition (olid &key (then 'sync) else)
  "Return the edition identified by OLID.
OLID may be a bare OLID such as \"OL7353617M\", a key such as
\"/books/OL7353617M\" or an Open Library URL.

The response is an alist with keys such as \"key\", \"title\",
\"subtitle\", \"authors\", \"publishers\", \"publish_date\",
\"number_of_pages\", \"isbn_10\", \"isbn_13\", \"covers\",
\"works\", \"languages\" and \"identifiers\".

Return the decoded response synchronously; when THEN is a function,
return the curl process instead, call THEN with the response, and
call ELSE with a `plz-error' if the request fails.  See
`openlibrary--request'."
  (openlibrary--request
   (format "/books/%s.json" (openlibrary--olid olid))
   nil then else))

(cl-defun openlibrary-edition-by-isbn (isbn &key (then 'sync) else)
  "Return the edition with ISBN.
ISBN may contain hyphens and spaces and may be prefixed with
\"ISBN:\"; the request follows Open Library's redirect from
\"/isbn/ISBN.json\" to the edition.

The response has the same shape as the one returned by
`openlibrary-edition'.

Return the decoded response synchronously; when THEN is a function,
return the curl process instead, call THEN with the response, and
call ELSE with a `plz-error' if the request fails.  See
`openlibrary--request'."
  (openlibrary--request
   (format "/isbn/%s.json" (url-hexify-string (openlibrary--isbn isbn)))
   nil then else))

;;;; Authors API

(cl-defun openlibrary-author (olid &key (then 'sync) else)
  "Return the author identified by OLID.
OLID may be a bare OLID such as \"OL23919A\", a key such as
\"/authors/OL23919A\" or an Open Library URL.

The response is an alist with keys such as \"key\", \"name\",
\"personal_name\", \"birth_date\", \"death_date\", \"bio\",
\"photos\", \"links\", \"wikipedia\" and \"remote_ids\".

Return the decoded response synchronously; when THEN is a function,
return the curl process instead, call THEN with the response, and
call ELSE with a `plz-error' if the request fails.  See
`openlibrary--request'."
  (openlibrary--request
   (format "/authors/%s.json" (openlibrary--olid olid))
   nil then else))

(cl-defun openlibrary-author-works (olid &key limit offset (then 'sync) else)
  "Return the works of the author identified by OLID.
LIMIT is the maximum number of works and OFFSET the number of
works to skip.

The response is an alist with keys \"size\", \"links\" and
\"entries\"; each entry is a work object as returned by
`openlibrary-work'.

Return the decoded response synchronously; when THEN is a function,
return the curl process instead, call THEN with the response, and
call ELSE with a `plz-error' if the request fails.  See
`openlibrary--request'."
  (openlibrary--request
   (format "/authors/%s/works.json" (openlibrary--olid olid))
   `(("limit" . ,limit)
     ("offset" . ,offset))
   then else))

;;;; Subjects API

(cl-defun openlibrary-subject (subject
                               &key limit offset published-in ebooks
                               (then 'sync) else)
  "Return the Open Library subject page for SUBJECT.
SUBJECT is a subject slug such as \"science_fiction\" or
\"love\"; spaces and capital letters are accepted.

LIMIT is the maximum number of works and OFFSET the number of
works to skip.  PUBLISHED-IN restricts works by publication date,
either a single year or an interval such as \"1900-1950\".  When
EBOOKS is non-nil, only works with available e-books are returned.

The response is an alist with keys such as \"key\", \"name\",
\"subject_type\", \"work_count\", \"works\" and \"ebook_count\".

Return the decoded response synchronously; when THEN is a function,
return the curl process instead, call THEN with the response, and
call ELSE with a `plz-error' if the request fails.  See
`openlibrary--request'."
  (openlibrary--request
   (format "/subjects/%s.json" (url-hexify-string (format "%s" subject)))
   `(("limit" . ,limit)
     ("offset" . ,offset)
     ("published_in" . ,published-in)
     ("ebooks" . ,(and ebooks "true")))
   then else))

;;;; Books API

(cl-defun openlibrary-books (bibkeys &key (jscmd "data") (then 'sync) else)
  "Return bibliographic data for BIBKEYS from the Books API.
BIBKEYS is a string or a list of strings such as
\"ISBN:9780140328721\", \"OLID:OL7353617M\", \"LCCN:...\" or
\"OCLC:...\".  JSCMD selects the amount of data returned; it is
either \"data\" (the default) or \"viewapi\".

The response is an alist keyed by the requested bibkeys; each
value is an alist with keys such as \"key\", \"title\", \"authors\",
\"publishers\", \"publish_date\", \"number_of_pages\" and
\"identifiers\".

Return the decoded response synchronously; when THEN is a function,
return the curl process instead, call THEN with the response, and
call ELSE with a `plz-error' if the request fails.  See
`openlibrary--request'."
  (openlibrary--request
   "/api/books"
   `(("bibkeys" . ,(if (listp bibkeys)
                       (mapconcat #'identity bibkeys ",")
                     bibkeys))
     ("format" . "json")
     ("jscmd" . ,jscmd))
   then else))

;;;; Covers API

(cl-defun openlibrary-cover-url (id &key type size default)
  "Return the URL of the cover image for ID.

ID is a cover id, an OLID, an ISBN, an OCLC number or an LCCN,
depending on TYPE.  TYPE is `id' (the default), `olid', `isbn',
`oclc' or `lccn'.  SIZE is `S', `M' (the default) or `L'.

When DEFAULT is nil, append \"?default=false\" so that a missing
cover returns HTTP 404 instead of a blank image; when DEFAULT is
non-nil, return the URL as is.

For example:

  (openlibrary-cover-url \"9780140328721\" :type \='isbn :size \='L)"
  (format "%s/b/%s/%s-%s.jpg%s"
          (string-remove-suffix "/" openlibrary-covers-base-url)
          (downcase (format "%s" (or type 'id)))
          (url-hexify-string (format "%s" id))
          (upcase (format "%s" (or size 'M)))
          (or (unless default "?default=false") "")))

(cl-defun openlibrary-download-cover (id filename
                                         &key type size (then 'sync) else)
  "Download the cover image for ID to FILENAME.
FILENAME must not exist; see `openlibrary-cover-url' for TYPE and
SIZE.

Return FILENAME synchronously; when THEN is a function, return the
curl process instead, call THEN with FILENAME, and call ELSE with a
`plz-error' if the request fails.  See `openlibrary--request'."
  (plz 'get (openlibrary-cover-url id :type type :size size)
    :headers `(("User-Agent" . ,openlibrary-user-agent))
    :connect-timeout openlibrary-connect-timeout
    :timeout openlibrary-timeout
    :as `(file ,(expand-file-name filename))
    :then then
    :else else))

(provide 'openlibrary)
;;; openlibrary.el ends here
