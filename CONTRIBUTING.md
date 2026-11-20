# Contributing to Lantern VNC

Lantern is a free native VNC viewer for Apple Silicon Macs. Useful contributions include reproducible bug reports, display and input fixes, accessibility improvements, clearer documentation, and focused tests.

## Start with a problem

Read the [wiki](docs/wiki/Home.md) and search [existing issues](https://github.com/py-killer/lantern-vnc/issues) before opening a new issue. For a larger change, describe the problem and intended behavior in an issue before implementing it. Small fixes can go straight to a pull request.

For display problems, include the remote resolution, Mac window size, display backing scale, zoom setting, and steps that expose the problem. Explain which desktop edge or control you cannot reach. Redact screenshots and diagnostics: issues are public, and passwords, private server addresses, clipboard contents, and personal desktop information do not belong in them.

Report security concerns using [SECURITY.md](SECURITY.md).

## Build and check a change

Development requires an Apple Silicon Mac, Xcode command-line tools, and CMake 3.16 or later. Python 3 is used by the mock-server tests and source packaging. The source distribution includes its VNC and JPEG dependencies.

```sh
./scripts/build-deps.sh
./scripts/build-app.sh
./tests/run-tests.sh
TEST_SANITIZE=1 ./tests/run-tests.sh
./tests/run-display-tests.sh
```

Run checks relevant to the change and report their results. Network tests use a local mock VNC server; they do not require a connection to a real desktop. Automated protocol tests do not establish that the Mac UI looks correct. The display test script runs geometry checks and an offscreen native GPU harness; exit 77 means native testing was unavailable, not that it passed. Display changes also need the applicable manual cases in the [release checklist](docs/RELEASE_CHECKLIST.md).

Keep commits focused. Explain the trigger, the previous behavior, and the resulting behavior in the pull request. Include screenshots for visible changes, plus the window size and display scale used. Mark checks that were not run and state why.

## Implementation expectations

- Keep network work off the main thread and serialize writes to a VNC connection.
- Preserve input suppression in View only mode, release held keys and buttons when focus is lost, and map pointer coordinates through the displayed image transform.
- Bound memory use for remote frames and clipboard data. Keep Metal texture writes separate from in-flight GPU reads.
- Do not add an account requirement, payment gate, expiry, or telemetry as a routine implementation choice.
- Save no VNC passwords in device profiles, logs, feedback files, or test artifacts.
- Update user documentation when controls or supported behavior change. Describe unfinished work as unreleased.

Avoid modifying vendored libraries unless the change is necessary. Identify any vendor patch, preserve notices, and explain how it will be maintained. Include new third-party dependencies and their licenses in the source distribution.

## License and community

By contributing, you agree that your original contribution is available under this project's GPL-2.0-or-later license. Include only work you have permission to contribute. Existing third-party notices retain their own terms.

Follow the [code of conduct](CODE_OF_CONDUCT.md). Project maintenance is best effort; opening an issue or making an optional contribution does not create a support deadline.
