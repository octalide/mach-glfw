# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- build: Vendor GLFW 3.4 and build it into target-specific static archives for
  Linux, Windows, and Darwin.
- ci: Build and run the vendored path on Linux and Darwin, cross-build and
  inspect the Windows PE, and exercise the Darwin system-library fallback.

### Fixed
- link: Attributed every raw GLFW import to the stable `glfw` dependency name
  across Linux, Windows, and Darwin.
- link: Materialized Zig's MinGW runtime archives and attributed GLFW's Win32
  and UCRT imports so Windows builds remain self-contained.
- link: Attributed the vendored Cocoa backend's foreign imports to libSystem,
  libobjc, and the Darwin frameworks that provide them.

### Changed
- manifest: Re-touched to RFC-exact totality per mach#1964/mach#1979.
- distribution: The vendored static GLFW build is now the default; system GLFW
  remains an explicit opt-in fallback.

## [0.3.0] - 2026-07-07

### Changed
- manifest: Migrated manifest layout to comply with the V2 manifest spec.
- dependency: Updated `mach-std` dependency to git URL.
