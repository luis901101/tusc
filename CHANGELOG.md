The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Types of changes
- `Added` for new features.
- `Changed` for changes in existing functionality.
- `Deprecated` for soon-to-be removed features.
- `Removed` for now removed features.
- `Fixed` for any bug fixes.
- `Security` in case of vulnerabilities.

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
