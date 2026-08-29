# Build a website in beam-lisp, from zero

This is a hands-on tutorial. By the end you will have built a real blog: a set
of HTML files you can put on any web host. Then you will see how the *same code*
can also run as a live, interactive app — no rewrite.

You need no prior beam-lisp. We explain every piece as we go. Every code block
here is copied from a program that actually runs; you can type them in and get
the same output.

> **What is "SSG"?** Static Site Generation. Instead of a server that builds a
> page every time someone visits, you build all the pages **once**, ahead of
> time, into plain `.html` files. They load instantly and can be hosted
> anywhere. A blog, a docs site, a landing page — these are perfect for SSG.

---

## The one big idea

In beam-lisp, **a web page is just a function that returns data.** That's the
whole thing. You write a function; it returns a description of a page; a helper
turns that description into HTML text; you write the text to a file.

There is no template language to learn, no special file format. A page is data,
and you already know how to make data.

Let's see the smallest possible version.

---

## Step 1 — Hello, HTML

Make a file called `hello.bl` and put this in it:

```clojure
(ns hello
  (:require [live.hiccup :as h]))

(println (h/hiccup->html [:h1 "Hello, world"]))
```

Run it:

```
mix beam_lisp.run --path priv hello.bl
```

Output:

```
<h1>Hello, world</h1>
```

Let's read that line by line.

- `(ns hello …)` — every file starts by naming itself. `hello` is this file's
  name. Think of it like the title at the top of a document.
- `(:require [live.hiccup :as h])` — we want to use the HTML helper. It lives in
  a module called `live.hiccup`. `:as h` means "let me call it `h` for short."
- `[:h1 "Hello, world"]` — **this is the page.** It's a vector (a list in square
  brackets). The first item, `:h1`, is the HTML tag. The rest are its contents.
- `h/hiccup->html` — the helper. It takes that vector and returns the HTML
  string `<h1>Hello, world</h1>`.

That vector form — `[:tag ...contents]` — is called **hiccup**. It's how we
describe HTML as plain data.

---

## Step 2 — Nesting and attributes

Real pages have tags inside tags, and tags have attributes (like `class` or
`href`). Here's how both look:

```clojure
[:div {:class "card"}
 [:h2 "A title"]
 [:p "Some text."]]
```

Two new things:

1. **Attributes** go in a map (curly braces) right after the tag:
   `{:class "card"}`. This becomes `class="card"`.
2. **Children** are just more hiccup vectors, listed after. A `:div` containing
   an `:h2` and a `:p`.

Render it and you get:

```html
<div class="card"><h2>A title</h2><p>Some text.</p></div>
```

### A handy shortcut for classes and ids

Writing `{:class "card"}` every time is tedious. Hiccup lets you attach a class
or id directly to the tag with `.` and `#`:

```clojure
[:div.card "..."]            ; <div class="card">
[:div#main "..."]            ; <div id="main">
[:div#main.card.wide "..."]  ; <div id="main" class="card wide">
```

`.card` adds a class, `#main` sets the id. You can stack classes: `.card.wide`.
Use whichever reads best — the map form and the shortcut do the same thing.

### Text is safe by default

If your text contains characters that mean something in HTML — like `<`, `>`, or
`&` — hiccup escapes them for you, so they show up as literal characters instead
of breaking the page:

```clojure
(h/hiccup->html [:p "5 < 10 & rising"])
;; → <p>5 &lt; 10 &amp; rising</p>
```

You never have to think about this. It's automatic, and it's what keeps a
website from being broken (or hacked) by stray punctuation in your content.

---

## Step 3 — A list from data

The real power shows up when the page is built from data. Say you have a list of
names and want a bullet for each. Use `for`:

```clojure
[:ul
 (for [name ["Ada" "Alan" "Grace"]]
   [:li name])]
```

`for` walks the list and produces one `[:li …]` per name. The result:

```html
<ul><li>Ada</li><li>Alan</li><li>Grace</li></ul>
```

This is the key move: **your page is a function of your data.** Change the data,
the page changes. You never hand-write repetitive HTML.

> **A note on keys.** When you build a list from data, give each item a `:key`
> that uniquely identifies it: `[:li {:key name} name]`. For a static site it
> doesn't matter yet, but the moment you make the page *live* (Step 8), keys let
> the system update exactly the one row that changed instead of redrawing the
> whole list. Get in the habit now.

---

## Step 4 — Where does the data come from?

You could hard-code a list, but a website needs somewhere to keep its content.
beam-lisp has a built-in database called **datom**. You don't need to install or
configure anything — it's just there.

Think of datom as a place to store facts. Here we store some blog posts:

```clojure
(ns blog
  (:require [live.hiccup :as h] [datom]))

(def db
  (let [conn (datom/connect
               [{:db/ident :post/slug  :db/valueType :db.type/string :db/unique :db.unique/identity}
                {:db/ident :post/title :db/valueType :db.type/string}
                {:db/ident :post/date  :db/valueType :db.type/string}
                {:db/ident :post/body  :db/valueType :db.type/string}])]
    (datom/transact! conn
      [{:db/id -1 :post/slug "hello"  :post/title "Hello World" :post/date "2026-08-01"
        :post/body "This is my first post."}
       {:db/id -2 :post/slug "why-bl" :post/title "Why beam-lisp" :post/date "2026-08-15"
        :post/body "Because a page is just a function of data."}])
    (datom/db conn)))
```

That's a lot at once — let's unpack it slowly.

- `datom/connect` opens a database. The list you pass it is the **schema**: it
  describes what kinds of facts you'll store. Each entry names a field
  (`:post/title`), its type (`:db.type/string`), and sometimes a rule.
- `:post/slug` has `:db/unique :db.unique/identity`. A "slug" is the short
  name for a post used in its web address (like `hello` in
  `/posts/hello.html`). Marking it unique means no two posts can share one.
- `datom/transact!` adds facts. Each `{…}` is one post. The `:db/id -1` is a
  temporary id datom needs while inserting; the negative number is just a
  placeholder ("this is a new thing").
- `datom/db` takes a **snapshot** of the database — a fixed value you can read
  from. We save it as `db`.

You don't have to master datom to follow along. For now: *we put some posts in,
and `db` is how we read them back.*

---

## Step 5 — Reading the data back

To get the posts out, we **query** the database. A query says what facts you
want. Here's a function that returns all posts, newest first:

```clojure
(defn all-posts [db]
  (reverse
    (sort-by (fn [p] (:date p))
      (map (fn [row] {:slug (nth row 0) :title (nth row 1)
                      :date (nth row 2) :body (nth row 3)})
        (datom/q '[:find ?s ?t ?d ?b
                   :where [?e :post/slug ?s] [?e :post/title ?t]
                          [?e :post/date ?d] [?e :post/body ?b]] db)))))
```

Working from the inside out:

- `datom/q` runs a query. The `'[:find … :where …]` part is the query itself.
  `:find ?s ?t ?d ?b` says "find four things"; the `:where` lines say what they
  are — the slug, title, date, and body of each post. (The `?`-names are just
  labels, like blanks to fill in.)
- The query gives back rows, each a list of four values. `map` turns each row
  into a tidy map like `{:slug "hello" :title "Hello World" …}` so it's easier
  to use.
- `sort-by :date` then `reverse` puts the newest post first.

Now `(all-posts db)` gives us a clean list of posts. We're ready to make pages.

---

## Step 6 — A layout, and the pages

Every page on a site shares a shell: the `<html>`, `<head>`, `<title>`, `<body>`
wrapper. Write it once, as a function:

```clojure
(defn layout [title & content]
  (str "<!doctype html>"
    (h/hiccup->html
      [:html {:lang "en"}
       [:head
        [:meta {:charset "utf-8"}]
        [:title title]]
       [:body (into [:main] content)]])))
```

- `& content` means "gather any extra arguments into a list called `content`."
  So you can call `(layout "Title" thing1 thing2 …)` and all the things become
  the page body.
- `"<!doctype html>"` is the one bit of HTML that isn't a tag; we just glue it
  on the front with `str` (which joins strings).
- `(into [:main] content)` builds `[:main thing1 thing2 …]` — it drops all your
  content inside a `<main>` element.

Now the two pages. The index (the front page, listing every post):

```clojure
(defn index-page [db]
  (layout "My Blog"
    [:h1 "My Blog"]
    [:ul (for [p (all-posts db)]
           [:li [:a {:href (str "/posts/" (:slug p) ".html")} (:title p)]
                " — " (:date p)])]))
```

For each post it makes a list item with a link. The link's address is built from
the post's slug: `/posts/hello.html`. `:a` is a link, `:href` is where it goes.

And a page for a single post:

```clojure
(defn post-page [p]
  (layout (:title p)
    [:article
     [:h1 (:title p)]
     [:p.date (:date p)]
     [:p (:body p)]
     [:a {:href "/index.html"} "← back"]]))
```

It takes one post `p` and lays out its title, date, body, and a link home.

Notice: **these are just functions.** You can test a page in isolation by
calling it — `(index-page db)` returns a string. No server needed to check your
work.

---

## Step 7 — Build: write the files

A "static site generator" sounds fancy. It's this: call each page function and
save the result to a file.

```clojure
(defn build [db out]
  (File/mkdir_p (str out "/posts"))
  (File/write (str out "/index.html") (index-page db))
  (doseq [p (all-posts db)]
    (File/write (str out "/posts/" (:slug p) ".html") (post-page p)))
  (+ 1 (count (all-posts db))))
```

- `File/mkdir_p` makes the output folders (the `_p` means "make parent folders
  too, and don't complain if they already exist").
- `File/write` saves a string to a file. We write the index once…
- `doseq` walks every post and writes one file each. (`doseq` is like `for`, but
  for *doing* things — here, writing files — rather than collecting results.)
- The last line returns how many pages we made, just so we can print it.

Finally, run the build:

```clojure
(let [out "/tmp/blog_out"
      n (build db out)]
  (println (str "Built " n " pages → " out)))
```

That's the whole program. Run it:

```
mix beam_lisp.run --path priv examples/ssg/blog.bl
```

Output:

```
Built 3 pages → /tmp/blog_out
```

And the files are really there:

```
/tmp/blog_out/index.html
/tmp/blog_out/posts/hello.html
/tmp/blog_out/posts/why-bl.html
```

Open `/tmp/blog_out/index.html` in any browser. It's a real website. Here's what
one page looks like inside:

```html
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Hello World</title></head><body><main><article><h1>Hello World</h1><p class="date">2026-08-01</p><p>This is my first post.</p><a href="/index.html">← back</a></article></main></body></html>
```

You built a static site. To publish it, copy the `blog_out` folder to any web
host (GitHub Pages, Netlify, an S3 bucket, a plain server). No database or
runtime needs to be running — they're just files.

> **The complete program** is in `examples/ssg/blog.bl`. Run it and read it side
> by side with this tutorial.

---

## Step 8 — The "full stack" part: the same code, live

Here's where beam-lisp is different. A static page is frozen — it shows the data
as it was when you built it. Sometimes you want a page that **updates by itself**
when the data changes: a dashboard, a comment thread, a live score.

In most tools, that's a completely separate program from your static site. In
beam-lisp, **it's the same view functions.** You wrote `post-list` as a function
of data; a static build calls it once and freezes the result; a *live* version
calls it again whenever the data changes and sends the browser just the
difference.

Let's prove it. Here's a small view fragment:

```clojure
(defn post-list [db]
  [:ul (for [p (sort (datom/q '[:find ?s ?t
                                :where [?e :post/slug ?s] [?e :post/title ?t]] db))]
         [:li {:key (first p)} (second p)])])
```

**Static use** — render it to a string for a file, exactly like before:

```clojure
(h/hiccup->html (post-list (datom/db conn)))
;; → <ul><li data-key="a">First</li></ul>
```

**Live use** — hand the *same function* to a socket. Now, when the data changes,
connected browsers update automatically:

```clojure
(defn live-view [db _sess _locals]
  [:main (post-list db)])          ; the SAME post-list fragment

(live.socket/mount {:view live-view :shared conn :sink me :intents {}})
;; browser shows: <main><ul><li data-key="a">First</li></ul></main>

;; later, someone adds a post…
(datom/transact! conn [{:db/id -1 :post/slug "b" :post/title "Second"}])
;; the browser receives ONLY the change, not the whole page:
;;   [[:insert [0] "b" 1 [:li {:key "b"} "Second"]]]
```

That last line is the payoff. The system didn't re-send the page. It figured out
that exactly one new `<li>` appeared and sent a single "insert" instruction. The
browser adds one element. This is why the `:key` from Step 3 matters — it's how
the system knows *which* item is new.

> **How the live half works** — the socket, events, and how a browser applies
> those changes — is its own topic. The runnable examples are in
> `examples/live/` (start with `examples/live/05-two-tabs.bl`, where two browser
> tabs update from one write). The point for *this* tutorial is simply: **you
> did not rewrite anything.** The function you wrote for the static site is the
> function that powers the live app.

---

## What you learned

- A page is **hiccup**: plain data, `[:tag {attrs} …children]`.
- `live.hiccup/hiccup->html` turns hiccup into an HTML string. Text is escaped
  for you; `.class` / `#id` shortcuts save typing.
- Your content lives in **datom**, a built-in database. `datom/q` reads it.
- A **page is a function** of that data — testable by just calling it.
- **Building the site** is writing each page function's output to a file with
  `File/write`. That's all an SSG is.
- The same view functions can drive a **live** app with no rewrite: static
  freezes them, live re-runs them and sends only the difference.

## Where to go next

- `examples/ssg/blog.bl` — the finished static blog from this tutorial.
- `examples/live/00-README.md` — the live layer, example by example.
- Try extending the blog: add a tag to each post, a page per tag, an "about"
  page. Each is just another function and another `File/write`.

## Quick reference

| you want | you write |
|---|---|
| an element | `[:div "text"]` |
| a class / id | `[:div.card "…"]` / `[:div#main "…"]` |
| attributes | `[:a {:href "/x"} "link"]` |
| a list from data | `[:ul (for [x xs] [:li {:key x} x])]` |
| render to HTML | `(live.hiccup/hiccup->html tree)` |
| a full page | wrap in a `layout` fn returning `(str "<!doctype html>" …)` |
| read your data | `(datom/q '[:find … :where …] db)` |
| save a file | `(File/write "path.html" html-string)` |
| make folders | `(File/mkdir_p "path/to/dir")` |
