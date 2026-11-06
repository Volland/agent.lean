module

public import AgentLean
meta import AgentLean.Meta

/-!
# Example agents

The agents the tests, the golden traces and the reference bundle use. They exercise every tool
executor, the policy vocabulary and agent-as-tool.
-/

@[expose] public section

namespace Examples
open AgentLean AgentLean.Formula

structure AddArgs where
  a : Int
  b : Int
  deriving ToJson, FromJson, ToolSchema

/-- A pure tool: runs inside `step`, no host round trip. -/
def add : Tool AddArgs Int where
  name := "add"
  description := "Add two integers"
  executor := .pure
  idempotent := true
  run x := .ok (x.a + x.b)

structure TransferArgs where
  to : String
  amount : UInt32
  memo : Option String
  deriving ToJson, FromJson, ToolSchema

structure Receipt where
  ok : Bool
  ref : String
  deriving ToJson, FromJson, ToolSchema

/-- A host tool that moves money: not idempotent, sensitive, positive amounts only. -/
def transfer : Tool TransferArgs Receipt where
  name := "transfer"
  description := "Send money to a contact"
  executor := .host "bank.transfer"
  idempotent := false
  sensitive := true
  pre x := x.amount > 0
  post _ r := !r.ref.isEmpty

structure ConfirmArgs where
  question : String
  deriving ToJson, FromJson, ToolSchema

structure Confirmed where
  confirmed : Bool
  deriving ToJson, FromJson, ToolSchema

def confirmUser : Tool ConfirmArgs Confirmed where
  name := "confirm_user"
  description := "Ask the user to confirm an action"
  executor := .host "ui.confirm"
  idempotent := true

structure FetchArgs where
  url : String
  deriving ToJson, FromJson, ToolSchema

/-- Returns web content: untrusted. -/
def webFetch : Tool FetchArgs String where
  name := "web_fetch"
  description := "Fetch a web page as text"
  executor := .host "net.fetch"
  idempotent := true
  untrusted := true

structure EmailArgs where
  to : String
  body : String
  deriving ToJson, FromJson, ToolSchema

def sendEmail : Tool EmailArgs Bool where
  name := "send_email"
  description := "Send an email"
  executor := .host "mail.send"
  idempotent := false

structure LookupArgs where
  key : String
  deriving ToJson, FromJson, ToolSchema

/-- An io tool, run by the Lean driver. -/
def lookup : Tool LookupArgs String where
  name := "lookup"
  description := "Look up a configuration value"
  executor := .io
  idempotent := true
  runIO x := pure (.ok s!"value-of-{x.key}")

structure DeleteArgs where
  scope : String
  deriving ToJson, FromJson, ToolSchema

def deleteAll : Tool DeleteArgs Bool where
  name := "delete_all"
  description := "Delete everything"
  executor := .host "data.delete"
  idempotent := false

/-! ## Policies -/

policy payLimit := guard "transfer" "amount ≤ 100" (argNat "amount" (· ≤ 100))
  because "transfers above 100 need a human"
policy confirmBeforePay := requiresBefore "transfer" "confirm_user"
  because "the user must confirm every payment"
policy fetchLimit := atMostPerTurn "web_fetch" 3
  because "at most 3 fetches per user turn"
policy noEmailAfterUntrusted := confirmAfterUntrusted "send_email" "confirm_user"
  because "untrusted content may not trigger email without confirmation"
policy noDelete halt := ¬ₚ call! "delete_all"
  because "deleting everything is never allowed"

/-! ## Agents -/

def assistant : Agent where
  name := "assistant"
  system := "You are a careful assistant. Use tools when needed."
  tools := #[add.erase, transfer.erase, confirmUser.erase, webFetch.erase, sendEmail.erase,
             lookup.erase, deleteAll.erase, Agent.asTool "researcher" "research" "Delegate research"]
  policies := #[payLimit, confirmBeforePay, fetchLimit, noEmailAfterUntrusted, noDelete]
  budget := { steps := 64, toolCalls := 10, tokens := 100000 }

def researcher : Agent where
  name := "researcher"
  system := "You research a question with web_fetch and answer briefly."
  tools := #[webFetch.erase]
  policies := #[fetchLimit]
  budget := { steps := 64, toolCalls := 10, tokens := 50000 }

def env : Env := { agents := #[assistant, researcher] }

end Examples
