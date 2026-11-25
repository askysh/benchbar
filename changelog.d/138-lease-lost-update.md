### Linux and WSL

- On Ubuntu 25.10 and later, whose `mkdir` comes from uutils coreutils, two `benchbar lease take` runs at once no longer lose a lease, and two benchbar runs no longer both take the run lock of a state folder or a bench. That `mkdir` also says yes to the run that lost the race to make a lock folder, so benchbar now decides who holds a lock by a file only one run can create (#138).
