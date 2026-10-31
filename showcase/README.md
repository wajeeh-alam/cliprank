# ClipRank static showcase

This directory is the zero-cost, recruiter-facing GitHub Pages demo. It is a
buildless HTML/CSS/JavaScript site and does not call the Rails or FastAPI
services.

The bundled clips and displayed scores come from the synthetic real-media run
documented in the project README. They are deliberately labeled as sample data.
The application includes no analytics, forms, or upload handling; it needs no
API keys and makes no engagement or performance claims. GitHub Pages remains
subject to GitHub's own infrastructure logging and privacy terms.

Serve locally from the repository root:

```sh
python3 -m http.server 4173 --directory showcase
```

Then open <http://localhost:4173>.
