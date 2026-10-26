# scripts/

Repo maintenance scripts. Not part of the public skill.

## render_diagrams.py

Regenerates the architecture PNGs in:

- `templates/whatsapp-webhook/option-a-apex/architecture.png`
- `templates/whatsapp-webhook/option-b-node/architecture.png`
- `templates/teams-webhook/option-a-apex/architecture.png`
- `templates/teams-webhook/option-b-node/architecture.png`

Run after editing the script (e.g., to add a new flow or rename a node):

```bash
pip install matplotlib
python3 scripts/render_diagrams.py
```

The PNGs are committed to the repo. Don't `.gitignore` them.

## check_no_ascii_diagrams.py

Regression guard. Fails if any of the customer-facing architecture docs
(`docs/WHATSAPP.md`, `docs/TEAMS.md`, the four template READMEs) contain
box-drawing or arrow characters that indicate ASCII art has crept back in.

Architecture diagrams must be rendered PNGs.

Runs in CI on every PR via `.github/workflows/check-diagrams.yml`. To run
locally:

```bash
python3 scripts/check_no_ascii_diagrams.py
```

Exit code 0 = clean, 1 = ASCII art found.

## Adding new architecture diagrams

1. Add a new `render_diagram(...)` call to `render_diagrams.py`
2. Run `python3 scripts/render_diagrams.py` to generate the PNG
3. Reference it from the relevant README with `![alt](./architecture.png)`
4. Add the README path to `GUARDED_FILES` in `check_no_ascii_diagrams.py`
   so any future ASCII regression in that file fails CI
