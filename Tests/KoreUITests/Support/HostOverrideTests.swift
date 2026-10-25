import Testing

/// These suites change host-wide CLI/backend/network seams. Serialization must span the
/// suites as well as each suite's own tests; otherwise another chat can capture the wrong fake.
@Suite("host overrides", .serialized)
struct HostOverrideTests {}
