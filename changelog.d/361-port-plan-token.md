### Command line

- The token of `ports plan`, `ports setup` and `ports apply` is made from the plan itself (the benches, their modes, the port blocks and the service actions), not from the text of its preview. A preview that only reads differently, for example a step time in a new form, no longer makes `ports apply` say that the plan changed (#361).
