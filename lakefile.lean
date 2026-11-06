import Lake
open Lake DSL System

package agentLean where
  version := v!"0.1.0"
  description := "A tiny, verifiable agent library in Lean 4 that compiles to C"
  keywords := #["agents", "llm", "verification", "embedded", "ffi"]
  homepage := "https://github.com/Volland/agent.lean"
  license := "Apache-2.0"
  licenseFiles := #["LICENSE"]
  readmeFile := "README.md"
  leanOptions := #[⟨`autoImplicit, false⟩]

/-- The runtime library: imports only `Init` and allowlisted `Std` modules (checked by the bundle). -/
@[default_target]
lean_lib AgentLean where
  roots := #[`AgentLean]

/-- Compile-time only: deriving handlers and the `policy` command. Imported with `meta import`. -/
lean_lib AgentLeanMeta where
  roots := #[`AgentLean.Meta]

/-- Example agents used by the tests, golden traces and the reference bundle. -/
lean_lib Examples where
  roots := #[`Examples]

/-- Scenario tests; each test names the OpenSpec scenario it proves. -/
lean_lib Tests where
  roots := #[`Tests]

@[test_driver]
lean_exe tests where
  root := `Tests.Main
