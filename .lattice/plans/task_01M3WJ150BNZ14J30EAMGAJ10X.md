# C11-254: Web site: rebrand cmux → c11 across the site and all 19 locales

The web/ site (undeployed per platform/posthog.md) still brands itself cmux: ~1,779 'cmux' mentions on main, ~92 per locale messages file. Rename to c11 everywhere except deliberate lineage text (manaflow-ai/cmux credit) and the documented 'cmux' CLI compat alias. Land after the C11-248 web vocabulary PR #486 to avoid conflicts. Must be done before the site ever deploys. Carves the web-rebrand piece out of C11-142.
