### Windows tray

- A site's menu has **Move to Another Bench...** (#183), shown when `benchbar` lists `site move` and another bench is registered, and off for the default site. It asks for the bench and **Skip migrate**, shows the plan of `benchbar site move --dry-run --json` (the steps, the apps, the new address, what stays), answers a running bench with **Stop Bench**, then runs exactly that plan by its own token after you type the site name, with the progress of each step and the CLI's next steps at the end. A plan that changed in between asks you to **Review Again**.
