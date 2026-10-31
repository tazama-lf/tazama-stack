# rule-studio-devtestops env overlay
# ─────────────────────────────────────────────────────────────────────────────
# Applied by Set-ServerEnvOverlays (helpers.ps1) on Server B at deploy and
# restart time via sed. Each key=value line here replaces the matching line in
# extensions/env/rule-studio-devtestops.env, overriding the local-dev default.
#
# Format: KEY=VALUE  (one per line, no spaces around =)
# ─────────────────────────────────────────────────────────────────────────────

# GitHub organisation the rule repositories are created in
GITHUB_ORG_NAME=tazama-uat-rules
