# madon — published source (GNU AGPL-3.0)

This repository is the Corresponding Source for the modified Mastodon served at
<https://madon.co.il>, published to satisfy **GNU AGPL-3.0 §13**.

- **Base:** Mastodon `v4.6.4` — <https://github.com/mastodon/mastodon/tree/v4.6.4>
- **Our changes:** everything in `git diff v4.6.4..madon` — a few
  `config/initializers/` files plus `app/views/auth/registrations/new.html.haml`.
- **License:** GNU AGPL-3.0, inherited from upstream Mastodon (see `LICENSE`).

## How this repo is maintained

This is a **generated mirror**. Development happens in a private mono-repo; this
fork is regenerated as *upstream `v4.6.4` + our overlays* and force-pushed by a
sync script. Because it is generated, **issues and pull requests here may go
unmonitored**. A per-version `madon-v4.6.4` tag marks each published Mastodon
version. This repo is a 2-commit snapshot (upstream `v4.6.4` + overlays), not a
full clone — upstream's history lives at the link above.
