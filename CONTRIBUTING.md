# Contributing to rippled-zig

Thank you for your interest in contributing to rippled-zig! This project aims to become the premier XRP Ledger implementation in Zig, providing a robust, memory-safe, and educational platform for XRPL development.

## Project Vision

**Primary Goals**:
1. Achieve full parity with rippled (C++ implementation)
2. Provide the easiest way to learn XRPL protocol
3. Demonstrate modern Zig systems programming
4. Build the go-to layer for XRPL integration
5. Foster both Zig and XRPL developer communities

**Long-term Vision**:
- Maintain parity branch tracking latest rippled features
- Experimental branches for new features and optimizations
- Spin out specialized projects using rippled-zig as core
- Become reference implementation for memory-safe blockchain infrastructure

## Getting Started

### Prerequisites

- Zig 0.15.1 or later
- Basic understanding of XRPL OR Zig (you'll learn the other!)
- Git and GitHub account

### First Steps

1. **Fork and clone**:
```bash
git clone https://github.com/YOUR_USERNAME/rippled-zig.git
cd rippled-zig
```

2. **Build and test**:
```bash
zig build
zig build test
zig build run
```

3. **Explore the code**:
- Start with `src/main.zig` to understand flow
- Read `src/types.zig` for XRPL fundamentals
- Check `src/consensus.zig` for BFT algorithm
- Review tests to see examples
4. **Read the current policy docs before agent-driven work**:
- `PROJECT_STATUS.md` (current gate-backed status)
- `docs/CONTROL_PLANE_POLICY.md` (runtime profile boundaries)
- `docs/AGENT_AUTOMATION_POLICY.md` (least-privilege automation checklist)

## How to Contribute

### Areas We Need Help

**Critical (Parity with rippled)**:
- secp256k1 ECDSA implementation
- Remaining transaction types (7 more)
- Complete RPC methods (21 more)
- Full peer protocol
- Ledger history sync

**High Priority**:
- Performance optimization
- Comprehensive testing
- Documentation improvements
- Bug fixes
- Code review

**Learning-Friendly**:
- Additional test cases
- Code comments
- Example programs
- Tutorial content
- Bug reports

### Contribution Process

1. **Find or create an issue** for what you want to work on
2. **Comment** that you're taking it
3. **Fork** the repository
4. **Create a branch**: `git checkout -b feature/your-feature-name`
5. **Make your changes** with tests
6. **Run tests**: `zig build test` (must pass)
7. **Commit** with clear message
8. **Push** to your fork
9. **Create Pull Request** with description

### Code Standards

**Quality Requirements**:
- All tests must pass
- No compiler warnings
- Follow Zig standard formatting (`zig fmt`)
- Add tests for new features
- Document public APIs
- NO EMOJIS in code or documentation

**Code Style**:
```zig
// Good: Clear, documented, tested
pub const LedgerManager = struct {
    allocator: std.mem.Allocator,
    current_ledger: Ledger,
    
    pub fn init(allocator: std.mem.Allocator) !LedgerManager {
        // Implementation
    }
};

// Add tests
test "ledger manager initialization" {
    const allocator = std.testing.allocator;
    var manager = try LedgerManager.init(allocator);
    defer manager.deinit();
    
    try std.testing.expect(manager.current_ledger.sequence == 1);
}
```

### Commit Message Format

```
<type>: <short summary>

<detailed description>

Fixes #<issue-number>
```

**Types**: feat, fix, docs, test, refactor, perf, chore

**Example**:
```
feat: implement CheckCreate transaction type

- Add CheckCreate transaction structure
- Implement validation logic
- Add comprehensive tests
- Update transaction processor

Fixes #45
```

## Branch Strategy

### Main Branches

**main**: Production-ready code, tracks rippled parity  
**develop**: Integration branch for new features  
**experimental/***: Experimental features and optimizations  

### Feature Branches

**feature/***: New features  
**fix/***: Bug fixes  
**docs/***: Documentation improvements  
**test/***: Test additions  

### Release Process

1. Features merge to `develop`
2. Testing and validation on `develop`
3. Release candidates from `develop`
4. Stable releases merge to `main`

## Testing Requirements

### All contributions must include tests

**Unit Tests**:
```zig
test "your feature" {
    const allocator = std.testing.allocator;
    // Setup
    // Execute
    // Assert
}
```

**Integration Tests** (when applicable):
- End-to-end workflows
- Real network validation
- Performance tests

### Running Tests

```bash
# All tests
zig build test

# Specific module
zig test src/your_module.zig

# Validation tests
zig test tests/validation_suite.zig
```

## Documentation

### What to Document

- Public APIs (doc comments)
- Complex algorithms (inline comments)
- Design decisions (commit messages)
- Breaking changes (CHANGELOG.md)

### Documentation Style

**Clear and Technical**:
```zig
/// Calculate ledger hash from header fields.
/// 
/// Uses SHA-512 Half on canonical serialization of:
/// - Ledger sequence
/// - Parent hash
/// - Close time
/// - Account state hash
/// - Transaction hash
/// 
/// Returns 32-byte hash.
pub fn calculateHash(self: *const Ledger) LedgerHash {
    // Implementation
}
```

**NO EMOJIS** - Use clear text and standard formatting

## Learning Resources

### For XRPL Beginners

- Start with `src/types.zig` - understand XRP, amounts, accounts
- Read `src/ledger.zig` - see how ledgers work
- Study `src/consensus.zig` - learn Byzantine consensus
- Check XRPL docs: https://xrpl.org/docs

### For Zig Beginners

- Review Zig documentation: https://ziglang.org/documentation/
- Study our clean, well-tested code
- Start with simple modules like `src/types.zig`
- Ask questions in Discussions

### For Learning Both

This codebase is designed to teach BOTH:
- See how XRPL protocol works
- Learn Zig systems programming
- Understand distributed consensus
- Study production code structure

## Community

### Communication Channels

- **GitHub Issues**: Bug reports, feature requests
- **GitHub Discussions**: Questions, ideas, general discussion
- **GitHub Projects**: Track progress on major initiatives

### Code of Conduct

- Be respectful and professional
- Help others learn
- Focus on technical merit
- Welcome all skill levels
- Maintain high standards

## Project Goals

### Short Term (Next 6 Months)

- Achieve 95%+ rippled parity
- Complete all transaction types
- Full RPC API implementation
- Comprehensive test coverage
- Security audit

### Medium Term (6-12 Months)

- Performance optimization
- Testnet compatibility verified
- Production hardening
- Extensive documentation
- Growing contributor base

### Long Term (12+ Months)

- Full rippled parity maintained
- Mainnet compatibility
- Spin-out projects (libraries, tools)
- Reference implementation status
- Zig + XRPL community growth

## Roadmap to Parity

### Current Progress: ~75%

**Complete**:
- Core protocol (100%)
- Consensus (100%)
- Cryptography (95%)
- Transaction types (72% - 18/25)
- RPC methods (30% - 9/30)
- Infrastructure (100%)

**Remaining for Parity**:
- 7 transaction types
- 21 RPC methods
- Complete peer protocol
- Ledger sync
- Amendment system
- Performance tuning

**Estimated Timeline**: 3-6 months with active contributions

## Recognition

Contributors are recognized in:
- CONTRIBUTORS.md file
- Release notes
- GitHub contributor graphs
- Project documentation

## Questions?

- Check existing documentation
- Search closed issues
- Ask in GitHub Discussions
- Open a new issue

---

**Thank you for helping build the future of XRP Ledger infrastructure in Zig!**

**Together we'll create the most robust, educational, and extensible XRPL implementation.**
