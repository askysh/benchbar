---
title: "Privacy of this site"
description: "What the BenchBar documentation site counts about its visitors, who runs the counter, how to opt out, and what the BenchBar programs send."
---

This page is about the documentation site, <https://benchbar.akashmishra.com>.
For the programs, see [What the programs send](#what-the-programs-send).

## What the site counts

The site uses [Umami](https://umami.is), a web analytics tool. The
maintainer runs it at `analytics.akashmishra.com`. No other analytics
company receives the data. Umami sets no cookie.

A page view sends the URL path (not the query string), the referrer, the
browser language, the screen size, the browser and the operating system.
The request carries your IP address, as every web request does. Umami
uses it to find the location (country, region and city) and, hashed with
a value that changes every month, to tell visits apart. It does not
store the address. The page view has no cookie and no ID that follows
you to another site.

Besides page views, the site sends three custom events:

| Event | When | What it sends |
| --- | --- | --- |
| `command-copy` | You press the copy button of a code block. | The first line of the block, cut to 80 characters, and the page. |
| `download-click` | You click a link to a GitHub release. | The path of the link, and the page. |
| `outbound-click` | You click any other link that leaves the site. | The host and the path of the link, and the page. |

The script has `data-exclude-search`, so the query string of a page is
never sent, with a page view or an event. No event carries anything you
typed. The site has no forms and no sign in.

The script counts only on `benchbar.akashmishra.com`, so a local preview of
the docs is not counted. The code is `site/astro.config.mjs` and
`site/public/analytics-events.js` in the
[repository](https://github.com/askysh/benchbar).

## Why

The counts show which pages people read, whether a reader copied the
install command and whether a reader went to a download. They decide what
to write next. The data stays on the maintainer's server.

## How to opt out

- Block `analytics.akashmishra.com` with a content blocker. This works in
  every browser, and it is the way to opt out in Safari, which no longer
  has a Do Not Track setting.
- Or turn on **Do Not Track** in a browser that has the setting. The site
  honors it.
- Or run `localStorage.setItem('umami.disabled', 1)` in your browser's
  console on this site.

The site works the same with the counter off.

## What the programs send

The `benchbar` command line tool and the apps do not collect or send usage
data. They use the network for what you ask: Homebrew, git, apps and the
update check, which asks GitHub for the latest release. `benchbar report`
writes a zip on your computer with secrets removed. It sends nothing until
you attach it to an issue yourself.

BenchBar for Windows works the same way. See [Windows](windows.md#update).
