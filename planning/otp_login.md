# Planning: Login with OTP

This document outlines the implementation of OTP login functionality in `TeliDemoClient`.

## Goal
Enable users to log in to Telegram using their phone number and an OTP (One-Time Password).

## Proposed Changes

### `TeliDemoClient`
Add the following methods to `TeliDemoClient`:

- `Future<Map> setPhoneNumber(String phoneNumber)`: Invokes `setAuthenticationPhoneNumber`.
- `Future<Map> checkCode(String code)`: Invokes `checkAuthenticationCode`.
- `Future<Map> checkPassword(String password)`: Invokes `checkAuthenticationPassword` (for 2FA).

### `TeliDemoCredentials`
- No changes needed for now, as `phoneNumber` is already present.

## Implementation Steps
- [x] Add `setPhoneNumber` method to `TeliDemoClient`.
- [x] Add `checkCode` method to `TeliDemoClient`.
- [x] Add `checkPassword` method to `TeliDemoClient`.
- [x] Update `TeliDemoClient.init` logic (added `setTdlibParameters` as a helper).
- [x] Add unit tests for the new methods.
- [x] Update example to demonstrate OTP login.

## Verification Plan
- [x] Run `dart test` to ensure existing tests pass.
- [x] Add new tests in `test/telidemo_client_test.dart`.
