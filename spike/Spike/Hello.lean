module
meta import Spike.Meta
public section
hello_def greeting

/-- Hello-agent step: counts events, emits an effect string. -/
@[export agentlean_spike_step]
def spikeStep (n : UInt32) (ev : String) : String :=
  s!"\{\"step\":{n},\"effect\":\"echo\",\"event\":\"{ev}\",\"g\":\"{greeting}\"}"
end
