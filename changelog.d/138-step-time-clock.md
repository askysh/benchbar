### Command line

- `benchbar ports apply` and `benchbar ports setup` no longer say "The port plan changed" for a plan that did not change, when the computer's clock stepped back between the preview and the apply (a time sync, or WSL after the computer slept). A step that ran across such a step shows `0s`, not a negative time, in the step lines and in the JSON stream, and `benchbar run` (`elapsed_s`) and `benchbar wait` (`waited_s`, "not ready after") never report one (#138).
