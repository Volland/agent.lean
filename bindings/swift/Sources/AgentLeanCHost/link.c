/* SwiftPM needs one source file in a C target. The implementation is libagentlean.a, linked by
 * Package.swift from the host build of the bundle; this target only carries the module map. */
#include "../../../../c/agent.h"
