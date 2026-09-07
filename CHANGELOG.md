# Changelog

## [0.1.3-candidate.1] - 2026-09-07

### Added

- Change the administrator password from the VPS with `sudo slabctl changepass`.
  Hidden confirmation prompts replace the password and sign out existing browser
  sessions while preserving workspace data.

### Fixed

- Show a prominent completion banner, browser URL, and password guidance after
  optional setup, including when optional setup is interrupted.
- Explain when an existing administrator password was preserved on reinstall.
- Show runtime connection instructions even while domain TLS is pending.

This candidate retains the application images and database migrations from
stable `0.1.2`.
