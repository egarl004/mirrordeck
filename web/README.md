# Landing page

`index.html` is the whole site — one self-contained file, no build step and no
dependencies beyond Google Fonts. All illustrations are inline SVG (no stock
photography, so there are no image licenses to track), and the page follows the
viewer's light/dark preference.

## Deploying to GitHub Pages

```sh
git subtree push --prefix web origin gh-pages
```

Then in the repository settings, set Pages to deploy from the `gh-pages`
branch. The site appears at `https://<user>.github.io/mirrordeck/`.

For a custom domain, add a `CNAME` file to this directory containing the
domain, and point a DNS CNAME record at `<user>.github.io`.

## Analytics

**Already collecting, no setup:** `./scripts/stats.sh` reports release download
counts, repository views and clones, referrers, and stars. Download counts are
cumulative and never reset. GitHub keeps traffic data for only 14 days, so run
it periodically if you want a longer record.

For a download-and-go tool, **downloads are the number that matters** and they
are already counted. Page views mostly tell you how well a link performed.

**Page visits need a script on the page.** GitHub Pages serves no logs. Two
options that suit this project, both free and neither requiring a cookie
banner:

- **[Cloudflare Web Analytics](https://www.cloudflare.com/web-analytics/)** —
  free, no cookies, no account needed with Cloudflare beyond signup. One script
  tag with a token.
- **[GoatCounter](https://www.goatcounter.com)** — free for non-commercial and
  open source, open source itself, about 3 KB.

Both are a single `<script>` before `</body>` in `index.html`. Google Analytics
would also work but sets cookies, needs a consent notice, and is widely blocked
by exactly the audience this tool has.

**Search performance is separate.** [Google Search
Console](https://search.google.com/search-console) shows which queries surface
the site, impressions, click-through, and whether pages are indexed at all —
none of which analytics reports. Verify the domain, submit `sitemap.xml`, and
check back in a couple of weeks. [Bing Webmaster
Tools](https://www.bing.com/webmasters) does the same and also feeds DuckDuckGo.

## Before it goes live

- [ ] **Make the repository public.** Every source link on the page 404s while
      it is private.
- [ ] **Create a release** so `/releases/latest` resolves. The Download button
      points there.
- [x] **Sign and notarize the build.** Done — `NOTARIZE=1 ./scripts/package.sh`
      produces a build Gatekeeper accepts.
- [x] **Adopt a licence.** Done — GPL-3.0, see `LICENSE`.
- [ ] **Decide on the donation section.** `index.html` has a clearly marked
      `#support` section; delete it to launch without any donation mechanism.
