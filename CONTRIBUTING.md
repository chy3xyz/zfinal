# Contributing to ZFinal

First off, thank you for considering contributing to ZFinal! It's people like you that make ZFinal such a great tool.

## Code of Conduct

This project and everyone participating in it is governed by our Code of Conduct. By participating, you are expected to uphold this code.

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check the existing issues as you might find out that you don't need to create one. When you are creating a bug report, please include as many details as possible:

* **Use a clear and descriptive title**
* **Describe the exact steps which reproduce the problem**
* **Provide specific examples to demonstrate the steps**
* **Describe the behavior you observed after following the steps**
* **Explain which behavior you expected to see instead and why**
* **Include screenshots if possible**

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion, please include:

* **Use a clear and descriptive title**
* **Provide a step-by-step description of the suggested enhancement**
* **Provide specific examples to demonstrate the steps**
* **Describe the current behavior and explain which behavior you expected to see instead**
* **Explain why this enhancement would be useful**

### Pull Requests

* Fill in the required template
* Do not include issue numbers in the PR title
* Follow the Zig style guide
* Include thoughtfully-worded, well-structured tests
* Document new code
* End all files with a newline

## Development Process

1. Fork the repo
2. Create a new branch from `main`
3. Make your changes
4. Run tests: `zig build test`
5. Commit your changes
6. Push to your fork
7. Submit a Pull Request

### Coding Style

* Follow Zig's official style guide
* Use meaningful variable and function names
* Write comments for complex logic
* Keep functions small and focused

### Commit Messages

* Use the present tense ("Add feature" not "Added feature")
* Use the imperative mood ("Move cursor to..." not "Moves cursor to...")
* Limit the first line to 72 characters or less
* Reference issues and pull requests liberally after the first line

## Project Structure

```
zfinal/
├── src/           # Core framework code
├── demo/          # Example applications
├── tools/         # CLI tools (zf)
├── doc/           # Documentation
├── benchmark/     # Performance benchmarks
└── test/          # Test files
```

## Testing

Run all tests:
```bash
zig build test
```

Run specific demo:
```bash
zig build run-blog
zig build run-htmx
```

## Documentation

* Update documentation for any changed functionality
* Add examples for new features
* Keep README.md up to date

## Questions?

Feel free to ask questions in:
* GitHub Discussions
* GitHub Issues (with the `question` label)

Thank you for contributing! 🎉
