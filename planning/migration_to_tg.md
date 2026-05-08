# Planning: Migrate to Pure Dart 'tg' Package

This document outlines the implementation plan for switching from `telegram_universe` to the `tg` package.

## Goals
- Eliminate the database bottleneck caused by TDLib's SQLite implementation.
- Improve concurrency and speed for "pulling" messages.
- Simplify the codebase by using a pure Dart MTProto library.

## Tasks
- [x] Create `planning/migration_to_tg.md`.
- [x] Update `pubspec.yaml` dependencies (using local `tg` package).
- [x] Update `TeliCredentials` to store `phoneCodeHash`.
- [x] Refactor `TeliClient` to use `tg.Client`.
- [x] Update `example/teli_example.dart`.
- [x] Update `test/teli_client_test.dart`.

## Architecture
We are moving from a TDLib-based wrapper (C++ bridge) to a pure Dart MTProto client. This removes the need for native binaries and a dedicated database directory for most basic tasks.

## Verification
- Run `dart test` to ensure all functionality is preserved and optimized.
