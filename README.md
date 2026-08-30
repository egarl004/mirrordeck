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
