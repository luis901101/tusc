The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Types of changes
- `Added` for new features.
- `Changed` for changes in existing functionality.
- `Deprecated` for soon-to-be removed features.
- `Removed` for now removed features.
- `Fixed` for any bug fixes.
- `Security` in case of vulnerabilities.

## 4.0.0
### Changed
- **Breaking:** an upload with a `cache` set now resumes a previously started upload instead of creating a new one on every `startUpload()`. Override `generateFingerprint()` if your creation `url` is one time or pre signed, such as a Cloudflare Stream direct upload URL, since the default fingerprint is derived from it.
- The upload URL is now cached on every upload attempt, not only when the upload is created.
- `cancelUpload()` now always returns a future, which completes once the cancellation and its cache removal have been recorded, and returns `null` only for an already completed upload.
- Documented on `generateFingerprint()` what the fingerprint has to be stable and unique across.

### Fixed
- Fixed cached uploads never being read back, so an interrupted upload can now be resumed by a new client instance after an app restart or crash instead of silently starting over from zero.
- Fixed an upload failing outright when the cached upload URL has expired or was swept server side, which now falls back to creating a new upload.
- Fixed `TusStreamClient` uploading the wrong bytes when resuming a stream at a non zero offset.
- Fixed the cache mapping possibly being lost when the process exits right after a chunk lands on the server.
- Fixed a cancelled upload being resumed where it left off instead of starting over from the beginning.
- Fixed `pauseUpload()` and `cancelUpload()` being silently ignored when no request was in flight, or when the request in flight completed before they took effect.

## 3.0.0
### Added
- Added support for resuming uploads using a direct `uploadUrl`, allowing the client to skip the upload creation step without requiring a cache.
- Updated `TusClient` and `TusStreamClient` constructors to accept an optional `uploadUrl`.
- Added `clear()` method to `TusCache`, `TusMemoryCache`, and `TusPersistentCache`.
- Improved documentation and code examples in `README.md` and library files.
- Added comprehensive assertion checks for `url` and `uploadUrl` parameters.

### Changed
- Updated dart sdk constraints to `sdk: '>=3.10.0 <4.0.0'`

## 2.1.0
### Added
- Added `TusStreamClient` to support stream uploads.

### Changed
- Removed usage of `dart:io` to allow support for web.

### Fixed
- Fixed error with `TusPersistentCache` keys limit of 255 chars length, due to Hive limitation. _(Thanks [bthnkucuk](https://github.com/bthnkucuk) [PR-2](https://github.com/luis901101/tusc/pull/2))_

## 2.0.0
### Changed
- Changed `hive` dependency to `hive_ce`.

## 1.2.0
### Added
- Added `onError` callback to `startUpload()` function to allow getting errors through callback instead of thrown exceptions 

## 1.1.0+3
### Changed
- Updated `http` package version to `'>=0.13.0 <2.0.0'` for better compatibility.

## 1.1.0+2
### Added
- `TusUploadState` enum added to control the state of the tus upload
- `tusclient.state` to get the current upload state
- `tusclient.errorMessage` to get the last error message
- `cancelUpload` function added to `TusClient`

## 1.0.0+1
### Changed
- README.md updated

## 1.0.0
- Initial version.
