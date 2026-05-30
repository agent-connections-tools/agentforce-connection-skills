# Contributing

Thanks for your interest in improving the Custom Connections Skill. Here's how to contribute.

## Ways to contribute

- **Report a bug** — something didn't deploy correctly, or the skill generated wrong metadata? [Open an issue](https://github.com/agent-connections-tools/custom-connections-skill/issues/new).
- **Add a new response format template** — if your client uses a pattern we don't have (e.g., carousel, form, map pin), add it.
- **Improve the skill prompt** — make the Claude Code skill smarter about edge cases.
- **Fix docs** — typos, unclear instructions, missing steps.

## How to submit a change

1. Fork the repo
2. Create a branch (`git checkout -b my-change`)
3. Make your changes
4. Test the skill locally: run `claude` in the repo and type `/project:build-custom-connection` to make sure it still works
5. Commit and push
6. Open a Pull Request with a short description of what you changed and why

## Adding a new response format template

If you want to add a new response format (e.g., a carousel, a form, a location picker):

1. Add the XML template to `.claude/skills/build-custom-connection/SKILL.md` under the "Metadata templates" section
2. Add the format as an option in Step 1 question 2 (the "What response formats does your client need?" list) in both SKILL.md and `.claude/commands/build-custom-connection.md`
3. Add a row to the "Available Response Formats" table in `README.md`
4. Add an example to `GUIDE.md` under Step 4
5. If it's a channel-specific format set (like WhatsApp or Instagram), also add:
   - Template files in `templates/<channel>-response-formats/`
   - Webhook handler templates in `templates/<channel>-webhook/option-a-apex/` and `option-b-node/`
   - A solution guide doc at `docs/<CHANNEL>.md`
   - Channel-specific rules in the "Important rules" section of SKILL.md

Each response format needs:
- A `<description>` — tells the agent WHEN to use this format
- An `<input>` — valid JSON schema on a single line
- `<instructions>` — tells the agent HOW to use this format
- A `<masterLabel>` — display name

## Testing your changes

Run the skill locally and verify:
- It asks 4-5 questions (client name, formats, instructions, optional MIAW handoff, optional webhook handler)
- It auto-generates a surface ID
- The generated files are valid XML
- `deploy.sh` runs without errors against a test org (if you have one)

## Code of conduct

Be kind. Be helpful. We're all building this together.
