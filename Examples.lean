module

public import Examples.Agents

/-! Registers the example agents for `agent_new`. -/

initialize AgentLean.registerAgent Examples.assistant
initialize AgentLean.registerAgent Examples.researcher
