import Lake
open Lake DSL System

-- @tg: implements:: [[adr:0012]]
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

/-- The Lean-native driver: libcurl transport. Not part of the embedded runtime. -/
lean_lib AgentLeanDriver where
  roots := #[`AgentLean.Driver]

target agentCurl.o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "agent_curl.o"
  let srcJob ← inputTextFile <| pkg.dir / "c" / "agent_curl.c"
  let leanInc ← getLeanIncludeDir
  buildO oFile srcJob #["-I", leanInc.toString, "-fPIC", "-O2"] #[] "cc"

extern_lib agentcurl pkg := do
  let o ← fetch <| pkg.target ``agentCurl.o
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "agentcurl") #[o]

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


/-- Runs the example assistant through the Lean driver against an OpenAI-compatible endpoint. -/
lean_exe driver_demo where
  root := `Examples.DriverDemo


/-- Writes the golden traces in `traces/`. -/
lean_exe golden where
  root := `Tests.Golden

