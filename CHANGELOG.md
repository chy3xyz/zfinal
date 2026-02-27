# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2024-12-03

### Added
- **Core Framework**:
  - High-performance HTTP server based on Zig standard library.
  - RESTful routing system with parameter support.
  - `Context` object for handling requests and responses.
  - Middleware/Interceptor support (AOP).

- **Database & ORM**:
  - Active Record implementation inspired by JFinal.
  - Support for SQLite, MySQL, and PostgreSQL.
  - Connection pooling.
  - SQL template engine.

- **Web Features**:
  - HTMX support for dynamic web applications.
  - Static file serving.
  - File upload support (multipart/form-data).
  - Session management.
  - WebSocket support.
  - Cookie management.

- **CLI Tool (`zf`)**:
  - `new`: Create new projects (HTMX template default).
  - `generate`: Scaffold Controllers, Models, and Interceptors.
  - `api`: Generate JSON API controllers.
  - `build`: Build release binaries.
  - `serve`: Start development server.

- **Utilities (Kits)**:
  - `StrKit`: String manipulation.
  - `HashKit`: Hashing and encoding (MD5, SHA, Base64).
  - `DateKit`: Date and time handling.
  - `JsonKit`: JSON parsing and stringifying.
  - `FileKit`: File system operations.
  - `HttpKit`: HTTP utilities.
  - `SysKit`: System information.
  - `RegexKit`: Regular expression support.

- **Documentation**:
  - Comprehensive English and Chinese READMEs.
  - Detailed guides for Getting Started, Database, Advanced Features, etc.
  - Full tutorial for building a "Life3" application.
  - Installation scripts and guides.

### Changed
- Renamed CLI tool from `zfctl` to `zf`.
- Improved default project structure for better scalability.

### Security
- Added input validation helper (`Validator`).
- Implemented basic security headers.
