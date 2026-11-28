### Install

- After an update from 0.8.x, `benchbar doctor` warns that Homebrew's Redis on port 6379 is not used by the bench: the install of 0.8.3 and earlier started that service, and 0.9.0 does not need it. Stop it with `brew services stop redis` when nothing else uses it; [Update and migrate](https://benchbar.akashmishra.com/upgrade/) says more (#293).
