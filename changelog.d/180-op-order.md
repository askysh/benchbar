### Command line

- `benchbar op list` and `benchbar op status` put the newest run first even when two runs start in the same second or the computer's clock steps back between them. Before, the newest run (and so the app's list of running operations) could be shown below an older one (#180).
