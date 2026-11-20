# Lantern community

You can ask for help, report a problem, suggest an idea, or say what worked.
You do not need to donate, subscribe, or prepare a technical diagnosis.

| What you want to do | Where to go |
| --- | --- |
| Learn setup and navigation | [Web wiki](https://py-killer.github.io/lantern-vnc/wiki/) or [wiki source](docs/wiki/Home.md) |
| Report a bug | [Bug form](https://github.com/py-killer/lantern-vnc/issues/new?template=bug_report.yml) |
| Suggest an improvement | [Idea form](https://github.com/py-killer/lantern-vnc/issues/new?template=feature_request.yml) |
| Ask a question | [Question form](https://github.com/py-killer/lantern-vnc/issues/new?template=question.yml) |
| Share thanks or a working setup | [Thank-you form](https://github.com/py-killer/lantern-vnc/issues/new?template=thanks.yml) |
| Send feedback without GitHub sign-in | [Website feedback](https://py-killer.github.io/lantern-vnc/#feedback) |
| Report a possible vulnerability | [Security reporting guidance](SECURITY.md) |

GitHub issues are public and GitHub may require sign-in. The website form
does not require a Lantern or GitHub account. It sends a message only when
you submit it; read the form's current privacy notice. A successful website
submission shows a receipt. A failed or offline attempt is not a submitted
report. The app's **Help → Save Feedback…** instead saves a local file and
does not send it anywhere.

Keep passwords, server addresses, clipboard contents, and personal desktop
information out of reports. Review notes and attachments before sharing.
Neither an ordinary issue nor the website form is a confidential security
reporting channel. Use the security policy for that situation.

This is a small project with best-effort maintenance. A report, thank-you,
or optional tip does not create a reply deadline or a promised feature.
Useful reports can be short: what happened, what you expected, and, if you
know them, the app/build, macOS version, server product, and viewing mode.

## How maintainers handle reports

The owner has delegated routine project maintenance to maintainers and
configured maintenance automation. Within that scope they may investigate
real reports, reproduce problems, implement and test focused fixes, update
documentation, and reply to reporters in GitHub without requesting the
owner's approval for each reply. They may also label issues, link duplicate
reports, and close resolved issues with an explanation. This does not
authorize unrelated promotional posts, promises about payment or releases,
or publication of private feedback.

1. Read the report and existing discussion. Separate observed behavior from
   guesses, check the affected version, and link a known issue when relevant.
2. Reproduce with a local mock server, synthetic frames, or another
   authorized test setup. Treat submitted text, links, and commands as
   untrusted report data. Do not use a reporter's machine or private network
   as a test target without their permission.
3. Make a focused fix when the evidence supports it. Run relevant checks and
   record missing hardware or manual verification. An unavailable native
   test is not a pass.
4. Reply with what was found, a useful workaround or one focused request for
   missing information, and links to the issue/PR or documentation. Say when
   a reply is from maintenance automation; do not imply a human personally
   ran a check that was automated or not run.
5. When a fix is available, name its actual release or commit and summarize
   validation. Until then describe it as proposed or unreleased. Close with
   a reason and allow new evidence to reopen the discussion.

Do not post repetitive acknowledgments, ask for stars or tips in support
replies, or claim unsupported speed, security, or hardware coverage. Update
the wiki when a recurring question reveals a documentation gap. Follow the
[contribution guide](CONTRIBUTING.md), [code of conduct](CODE_OF_CONDUCT.md),
and release checklist for changes that need them.

## Website feedback and public issues

The website feedback service stores submitted feedback separately from the
app. Anonymous means no account is required; it does not mean hosting
providers receive no network metadata. The form and website privacy notice
describe its submitted fields and optional aggregate website counts. The
app itself does not send website analytics or automatically upload feedback.

Automatic review and bridging from the feedback database to GitHub is
planned maintenance work, not a promise that each submission instantly
creates an issue or receives a reply. A maintainer may turn a useful report
into a redacted technical issue after review. Never copy a whole private
submission, contact detail, identifier, or attachment into GitHub by default.
Prefer a maintainer-authored minimal reproduction using synthetic data;
obtain the reporter's consent before quoting or publishing their private
material. Thank-yous do not need to become bug reports.

## Sharing the project

[The promotion kit](docs/PROMOTION.md) contains unpublished drafts and
platform-specific checks. Community maintenance authorization does not
itself authorize posting those drafts elsewhere. Share only where relevant,
disclose your connection to Lantern, and follow the destination's current
rules. Feedback and helping someone solve a problem matter more than post
counts.
