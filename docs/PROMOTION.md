# Promotion kit — unpublished drafts

These drafts have not been posted. They are for an owner or explicitly
authorized publisher to adapt, verify, and submit. Routine GitHub support
work does not authorize external promotion. Use one relevant post or thread
entry, disclose the relationship to Lantern, and stay around to answer real
questions. Do not solicit votes, send unsolicited direct messages, repeat
removed posts to bypass moderation, or place promotion in another maker's
launch thread.

## Facts to preserve

| Topic | Wording supported by the current project |
| --- | --- |
| Release | [1.1.0-preview.2](https://github.com/py-killer/lantern-vnc/releases/tag/v1.1.0-preview.2), a preview, not a stable release. |
| Platform | Apple Silicon, arm64, macOS 13+. No Intel build. |
| App | Native AppKit interface and Metal renderer; connects directly to an existing VNC server. Built around TightVNC use. |
| Access | Free current version, no app account, subscription, expiry, or feature unlock. Optional support does not affect access. |
| Source | GPL-2.0-or-later application source, with corresponding dependency sources and notices. |
| Navigation | Readable Auto, Fit, explicit/custom local zoom, native scrollbars, Hand navigation, sidebar/fullscreen controls. Local zoom does not change server resolution. |
| Other features | Keyboard/mouse control, view only, optional text clipboard sharing, and up to three locally saved destinations. One active session. Saved profiles exclude passwords. |
| Privacy | The app has no analytics service, cloud relay, or licensing server. Explicit browser visits and website submissions are separate; read the website privacy notice. |
| Connection limits | This build does not encrypt VNC or supply an SSH/VPN tunnel. Use a trusted network or a separately secured route. No audio, file transfer, or relay service. |
| Installation | Ad hoc signed; Apple Developer ID signing/notarization is pending. Explain that before download. |
| Verification | [Published synthetic native/protocol results](TEST_RESULTS-1.1.0-preview.1.md) on one Mac configuration; physical display transitions and the manual hardware matrix remain open. |
| AI involvement | Development used substantial AI assistance. Do not imply all code was handwritten or invent development history. The source and test evidence are available for inspection. |

Do not claim higher speed, lower CPU use, lower latency, better security, or
broader compatibility than another viewer without a reproducible comparison.
Test assertion/session counts are coverage evidence, not benchmarks or
independent certification. Avoid claims about competitors' current pricing
or licenses unless they are checked separately.

Website: <https://py-killer.github.io/lantern-vnc/>
Release/downloads: <https://github.com/py-killer/lantern-vnc/releases/tag/v1.1.0-preview.2>
Source/issues: <https://github.com/py-killer/lantern-vnc>
Wiki: <https://py-killer.github.io/lantern-vnc/wiki/>

## Hacker News: human-only participation

The [current official HN guidelines](https://news.ycombinator.com/newsguidelines.html) prohibit generated or AI-edited text and automated posting. The earlier AI draft has been removed. Do not post, lightly rewrite, or automate an AI-authored HN submission or comment. Only the human owner may independently decide to participate and write their own contribution, following the live rules. HN must not be used primarily for promotion.

## r/macapps

**Not ready for posting:** the App Pile also requires Problem–Comparison–Pricing, two researched competitors with honest tradeoffs, and a website link. The old draft below lacks that complete comparison; it is reference material only. Follow the current [November App Pile](https://www.reddit.com/r/macapps/comments/1xks9uj/megathread_the_app_pile_november_2026/) instructions if preparing a future human-reviewed entry.

Rules checked on 20 November 2026 in the community's [published rules](https://www.reddit.com/r/macapps/).
Recheck before posting. Its main feed currently requires account eligibility
and PCP + Trust information, including a qualifying trust route. It also
requires an `[OS]` title prefix for open source and limits promotion frequency.
The new, unnotarized Lantern preview must not pretend to meet an unverified
trust route, account history, star count, or comparison requirement. Use the
current **App Pile** thread when eligible, following that thread's instructions;
do not present this draft as ready for an unrestricted main-feed post.

**Draft App Pile entry:**

> **[OS] Lantern VNC — free native viewer for Apple Silicon**
>
> Disclosure: I maintain this project, which was developed with substantial
> AI assistance. Lantern connects a Mac directly to an existing VNC server.
> Its AppKit/Metal interface includes readable Auto zoom, Fit, scrollbars,
> Hand navigation, keyboard/mouse control, view only, and optional clipboard
> text sharing.
>
> Pricing: the current version is free, with no app account, subscription,
> expiry, or paid unlock. Requirements: Apple Silicon and macOS 13+.
>
> It is **1.1.0-preview.2**, not a stable release. The download is ad hoc
> signed and not Apple-notarized. VNC transport is unencrypted; use a trusted
> LAN or a separate secure tunnel. Physical display-transition testing remains
> open. No Intel support, audio, or file transfer.
>
> [Official download and source](https://github.com/py-killer/lantern-vnc/releases/tag/v1.1.0-preview.2)
> · [Wiki](https://py-killer.github.io/lantern-vnc/wiki/)
>
> Feedback about large desktops, MacBook usability, and input mapping would
> help. A report or thank-you is welcome; no payment is needed.

If later preparing a main-feed post, satisfy the live rules in full. Any
required two-product comparison needs actual research or testing and an
honest account of where each product is better. Do not manufacture a
comparison merely to fill a posting template.

## r/selfhosted

Rules checked on 20 November 2026 in the community's [published rules and New Project Megathread guidance](https://www.reddit.com/r/selfhosted/).
New projects under three months belong in its current **New Project
Megathread**, whose template requests AI involvement disclosure. General
promotion has production-readiness requirements, which this preview must
not claim to meet. Lantern is a desktop client for a self-hosted VNC server,
not a newly self-hosted service or a Docker deployment. If that companion
tool does not fit the current thread, do not post it there. Check any later
tool/Wednesday rules before considering a standalone post.

**Draft megathread comment:**

> **Project:** Lantern VNC
>
> **Repository/download:** https://github.com/py-killer/lantern-vnc
>
> **Description:** A free GPL-2.0-or-later native Apple Silicon Mac client for
> an existing VNC server such as TightVNC. It uses AppKit and Metal and connects
> directly, without a Lantern account or relay. Local zoom, scrollbars, and
> Hand mode help navigate a large remote desktop. I maintain the project.
>
> **Deployment:** Download the macOS app, not a Docker image. Requires macOS
> 13+ and Apple Silicon; configure your own reachable VNC server separately.
> Source and setup docs are included. The current release is
> **1.1.0-preview.2**, ad hoc signed and not Apple-notarized. It does not encrypt
> VNC or create a secure tunnel, so use a trusted network or a separately
> established VPN/SSH tunnel. No audio or file transfer; physical display
> transitions still need manual testing.
>
> **AI involvement:** Substantial AI assistance in development. Source and
> recorded tests are public; there are no comparative benchmark claims.
>
> [Setup/wiki](https://py-killer.github.io/lantern-vnc/wiki/)
> · [Report a problem or idea](https://github.com/py-killer/lantern-vnc/issues/new/choose)

## GitHub Discussion welcome

Use this only after Discussions and a suitable category are enabled. It can
also be adapted into a pinned project issue; do not post duplicate welcome
threads in both places.

**Draft title:** Welcome — bugs, ideas, questions, and what worked

> Welcome to Lantern VNC. This is a free native viewer for Apple Silicon
> Macs connecting to an existing VNC server. The current release is a preview.
>
> Start with the [wiki](https://py-killer.github.io/lantern-vnc/wiki/). You can
> [report a bug, ask a question, suggest an idea, or share thanks](https://github.com/py-killer/lantern-vnc/issues/new/choose).
> If you prefer not to sign in to GitHub, use the
> [website feedback form](https://py-killer.github.io/lantern-vnc/#feedback).
>
> For a bug, describe what happened, what you expected, and any versions or
> viewing mode you know. Partial reports are welcome. Please remove passwords,
> addresses, clipboard text, and personal desktop information from reports
> and screenshots. Use the [security policy](https://github.com/py-killer/lantern-vnc/blob/main/SECURITY.md)
> for potential vulnerabilities.
>
> Maintenance is best effort, with no promised response time. Maintainers and
> configured maintenance automation may investigate, fix problems, and reply
> directly in project discussions. A reply should say what was actually
> checked and where a fix is available. Useful criticism and small thank-yous
> are both welcome; donations are never required.

## Before an authorized publisher posts

Confirm that the release asset downloads, source archive matches the release,
wiki/feedback links work, privacy wording matches the deployed website, and
the preview/notarization limits remain visible. Use only generated or
explicitly approved screenshots, never a private remote desktop. Recheck the
destination rules and account eligibility, choose the required venue/flair,
and arrange to answer questions. Keep a link to any published post to avoid
duplicate promotion. These checks do not themselves authorize publication.

## Trackable launch links (unpublished outside GitHub)

Use one source label for each permitted post; keep campaign values free of personal details.

- GitHub announcement: https://py-killer.github.io/lantern-vnc/?utm_source=github&utm_medium=community&utm_campaign=preview2
- macapps App Pile draft: https://py-killer.github.io/lantern-vnc/?utm_source=reddit_macapps&utm_medium=community&utm_campaign=preview2
- selfhosted megathread draft: https://py-killer.github.io/lantern-vnc/?utm_source=reddit_selfhosted&utm_medium=community&utm_campaign=preview2

These links count only visits that allow automatic website counts. The private owner dashboard is at https://lantern-vnc-mac.fts227.chatgpt.site/admin ; it is not part of the customer website navigation.

## Scope chosen on 21 November 2026

The owner selected **search visibility only for now**. Improve owned GitHub Pages content, structured metadata, internal links, sitemap and GitHub repository discovery. No recurring public-opportunity check, external recommendation reply, directory submission or additional social post is enabled by this search-only task. The earlier GitHub launch announcement is already published at https://github.com/py-killer/lantern-vnc/discussions/1 .

Search intent: a free VNC client for an Apple Silicon Mac, direct access to an existing server, and occasional/temporary tasks without another viewer account. Do not describe Lantern as zero-setup internet support, a RealVNC cloud-session replacement, an Intel/iOS/Windows client, an encrypted transport, or a stable/notarized release.
