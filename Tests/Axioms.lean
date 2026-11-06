module

public import AgentLean

/-! The axioms the main theorems rely on; `scripts/check_proofs.sh` fails on anything beyond
Lean's standard `propext`, `Classical.choice` and `Quot.sound`. -/

#print axioms AgentLean.monitor_sound
#print axioms AgentLean.final_done
#print axioms AgentLean.done_sticky
#print axioms AgentLean.allocate_le
#print axioms AgentLean.allocate_le_child
#print axioms AgentLean.stepAll_append
#print axioms AgentLean.Sse.feed_append
#print axioms AgentLean.Sse.feed_chunks
#print axioms AgentLean.Context.fit_fits
#print axioms AgentLean.Context.fit_head
#print axioms AgentLean.Context.fit_keeps_last_turn
