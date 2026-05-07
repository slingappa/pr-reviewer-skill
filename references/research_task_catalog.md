# Research Task Catalog (Deep Crawl)

This catalog converts the research basis sources and key sublinks into explicit review-task groups.
Each task should be evaluated as `pass`, `attention`, or `needs-input`.

## Group 1: Linux kernel submission checklist + submitting patches
Sources:
- https://docs.kernel.org/process/submit-checklist.html
- https://www.kernel.org/doc/html/latest/process/submitting-patches.html

Actionable tasks:
- Review code for correctness and maintainability before submission.
- Verify Kconfig dependencies/defaults/help text and menu placement.
- Provide/update docs for new user-visible behavior.
- Run style/tool checks (checkpatch and peer tooling).
- Build across meaningful configs/architectures.
- Run focused functional tests and regression tests.
- Explain problem statement, impact, and design tradeoff in commit message.
- Split changes into logical patches; isolate mechanical churn.
- Ensure recipient coverage (maintainers/subsystem owners).
- Handle sensitive security bugs with correct disclosure path.
- Respond to each review comment and track revision changes clearly.
- Use patient review cadence and avoid noisy resubmission.

## Group 2: QEMU patch workflow + coding style
Sources:
- https://www.qemu.org/docs/master/devel/submitting-a-patch.html
- https://www.qemu.org/docs/master/devel/style.html

Actionable tasks:
- Base patches on current master to reduce merge friction.
- Follow project coding style and language-usage constraints.
- Keep patches small and logically split.
- Separate code motion/refactor from behavior changes.
- Exclude irrelevant churn (format-only/noise in semantic patches).
- Write meaningful commit message with rationale/impact.
- Include legal/provenance metadata required by project policy.
- Include/expand tests; where possible include regression-first tests.
- Use submission tooling workflow (e.g., b4/git-publish equivalents).
- Ensure maintainers/reviewers are CC’d correctly.
- Keep revision changelog and preserve relevant Reviewed-by/Tested-by tags.
- Participate actively in review and close feedback loops.

## Group 3: Python core PR acceptance + lifecycle/triage
Sources:
- https://devguide.python.org/core-team/committing/index.html
- https://devguide.python.org/getting-started/pull-request-lifecycle/
- https://devguide.python.org/triage/triaging/

Actionable tasks:
- Confirm PR is against correct branch; backport policy followed.
- Ensure CLA/signature checks pass.
- Ensure CI checks and targeted tests pass.
- Run local patchcheck-equivalent automation.
- Validate backward compatibility and justify breaks strongly.
- Add docs updates for user/developer-visible behavior changes.
- Add news/release note entries when required.
- Keep PR focused/small and avoid unrelated edits.
- Ensure issue linkage and triage labels are complete.
- Ensure conflicts/review comments are resolved before merge.
- Ensure reviewer feedback includes concrete repro/validation details.
- Preserve metadata and consistency when reverting/backporting.

## Group 4: Kubernetes PR + release notes process
Sources:
- https://www.kubernetes.dev/docs/guide/pull-requests/
- https://www.kubernetes.dev/docs/guide/release-notes/
- https://raw.githubusercontent.com/kubernetes/community/master/contributors/guide/pull-requests.md
- https://raw.githubusercontent.com/kubernetes/community/master/contributors/guide/release-notes.md

Actionable tasks:
- Run local verify/test/integration targets prior to review.
- Ensure CLA and required automation checks pass.
- Keep PR scope focused and reviewable.
- Follow hold/WIP conventions for unfinished work.
- Follow code/API/convention docs for touched areas.
- Use KEP process where feature-level changes require it.
- Ensure e2e/CI expectations are satisfied.
- Follow commit message conventions.
- Add release notes for user/operator-visible changes.
- Include release note fields: Added/Changed/Fixed/Removed, action-required, affected API/flags/config.
- Validate release note quality (purpose, impact, grammar).
- Ensure ownership/approval gates and merge policy are met.

## Group 5: Google reviewer guide (standard + subpages)
Sources:
- https://google.github.io/eng-practices/review/reviewer/standard.html
- https://google.github.io/eng-practices/review/reviewer/looking-for.html
- https://google.github.io/eng-practices/review/reviewer/navigate.html
- https://google.github.io/eng-practices/review/reviewer/speed.html
- https://google.github.io/eng-practices/review/reviewer/comments.html
- https://google.github.io/eng-practices/review/reviewer/pushback.html

Actionable tasks:
- Approve when change improves overall code health; block net regressions.
- Review design/functionality before style nits.
- Evaluate complexity and readability debt.
- Ensure test adequacy proportional to risk.
- Ensure naming/comments/docs quality.
- Check consistency with local subsystem patterns.
- Ensure every changed line/aspect is reviewed or explicitly delegated.
- Record review scope when partial review is performed.
- Use quick response cadence without sacrificing depth.
- Write polite comments with rationale and actionable guidance.
- Label comment severity (blocking vs nit vs optional).
- Resolve conflicts through explicit consensus/escalation paths.

## Group 6: Go review/test comments norms (generalized)
Sources:
- https://go.dev/wiki/CodeReviewComments
- https://go.dev/wiki/TestComments

Actionable tasks:
- Enforce formatter/tool output consistency.
- Ensure doc comments/identifier documentation quality.
- Ensure explicit and structured error handling.
- Avoid panic-like control flow for expected errors.
- Ensure naming/initialisms are consistent and clear.
- Validate concurrency/lifetime cleanup semantics.
- Validate secure random/crypto API usage where applicable.
- Ensure tests are readable and provide actionable diffs.
- Ensure test names are human-readable and scoped.
- Prefer stable result assertions and full-structure comparisons where appropriate.
- Ensure helper usage improves test diagnostics and maintainability.
- Avoid introducing untracked TODO/FIXME debt.

## Group 7: Node.js PR responsibilities + writing tests/docs
Sources:
- https://raw.githubusercontent.com/nodejs/node/main/doc/contributing/pull-requests.md
- https://raw.githubusercontent.com/nodejs/node/main/doc/contributing/writing-tests.md
- https://raw.githubusercontent.com/nodejs/node/main/doc/contributing/writing-docs.md

Actionable tasks:
- Follow PR process steps: fork/branch/code/commit/rebase/test/push/open/update/land.
- Follow commit message rules (subsystem prefix/format/issue references).
- Mark breaking changes clearly.
- Satisfy required signoff/provenance rules for project policy.
- Run test suite relevant to changed components before and after review updates.
- Add regression tests for new behavior/bug fixes.
- Ensure docs updates and docs lint/build pass.
- Keep PR discussion responsive and incorporate review feedback quickly.
- Respect minimum wait/review windows when required.
- Ensure CI matrix is green before landing.
- Secure required reviewer approvals.
- Keep PR manageable and avoid mixed unrelated concerns.

## Group 8: Rust API guidelines checklist (language-agnostic API quality)
Sources:
- https://rust-lang.github.io/api-guidelines/checklist.html
- https://raw.githubusercontent.com/rust-lang/api-guidelines/master/src/checklist.md

Actionable tasks:
- Naming/casing/conversion methods are consistent and unsurprising.
- Interoperability traits/protocols are implemented where expected.
- Error types are meaningful and ergonomic.
- API docs are complete and include examples/failure behavior.
- Constructors/method placement favor predictability.
- Argument types encode intent (avoid ambiguous bool/option misuse).
- Validate arguments and avoid dangerous implicit behavior.
- Favor debuggability through useful diagnostics.
- Preserve future-proofing (encapsulation/compatibility strategies).
- Review release notes and metadata for API-impacting changes.
- Ensure compatibility and migration paths are explicit.
- Avoid exposing unstable internals in public API.

## Group 9: OWASP secure code review + supporting cheat sheets
Sources:
- https://cheatsheetseries.owasp.org/cheatsheets/Secure_Code_Review_Cheat_Sheet.html
- https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html
- https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html
- https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html
- https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html
- https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html
- https://cheatsheetseries.owasp.org/cheatsheets/Error_Handling_Cheat_Sheet.html

Actionable tasks:
- Perform trust-boundary review and data-flow tracing for changed paths.
- Validate input using allowlist-first strategy and robust canonicalization.
- Validate parsing/encoding/endianness at boundary points.
- Check injection-resistance patterns for command/query/template contexts.
- Verify authentication controls (MFA/re-auth/rate limit/recovery safety).
- Verify authorization controls (deny-by-default, per-request checks, least privilege).
- Verify object/resource access checks prevent IDOR/tampering.
- Verify cryptographic choices, key management, and key/data separation.
- Verify logging includes security events without exposing secrets/PII.
- Verify error handling does not leak stack traces/internal details to users.
- Check business-logic abuse and race-condition scenarios.
- Capture security review outcome and residual risk explicitly.

